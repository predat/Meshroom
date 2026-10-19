"""
MCP tools running the open project through the application's TaskManager, like the Compute and Submit buttons.

Statuses are reported as Meshroom exposes them (node and chunk status, execution mode, times): Meshroom has no
progress percentage, so none is given.
"""
import os
import time
from typing import List

import meshroom.core
from meshroom.mcp import background, pipeline
from meshroom.mcp.editing import checkTopLevelKeysKept, editState, findNode
from meshroom.mcp.rpc import LogCapture, Tool
from meshroom.mcp.tools import Session, ToolError, addList, makeTool, outputFiles

LOCAL = "local"
MAX_LOG_LINES = 2000
MAX_LOG_BYTES = 256 * 1024
FINAL_STATUSES = ("SUCCESS", "ERROR", "STOPPED", "KILLED")


def findNodes(graph, names) -> list:
    if names is None:
        return None
    if not isinstance(names, list) or not all(isinstance(n, str) for n in names) or not names:
        raise ToolError("INVALID_ARGUMENT", "'nodes' must be a non-empty list of node names")
    return [findNode(graph, name) for name in names]


def chunkDescription(chunk) -> dict:
    status = chunk.status
    return {
        "chunk": chunk.chunkIndex,
        "status": status.status.name,
        "execMode": status.execMode.name,
        "elapsedTime": round(status.elapsedTime, 3),
        "startDateTime": status.startDateTime or None,
        "endDateTime": status.endDateTime or None,
        "hostname": status.hostname or None,
    }


def nodeStatus(node) -> dict:
    return {
        "name": node.name,
        "status": node.globalStatus,
        "execMode": node.globalExecMode,
        "elapsedTime": round(node.elapsedTime, 3),
        "chunks": [chunkDescription(c) for c in node.chunks] if node.chunksCreated else [],
    }


def computationState(editor) -> dict:
    return {"computingLocally": editor.isComputingLocally(), "computingExternally": editor.isComputingExternally()}


# Submission

def submissionPlan(graph, nodes, force: bool) -> tuple:
    """
    Nodes to process to compute 'nodes' (all the leaves if None), and the already computed ones skipped. A computed
    node has the SUCCESS status for its current UID (its cache folder is named after it). With 'force', all the
    dependencies are processed again, as TaskManager.compute(forceCompute=True) does.
    """
    startNodes = [n for n in (nodes or graph.getLeafNodes(dependenciesOnly=True)) if not n.isBackdropNode]
    if force:
        return graph.dfsOnFinish(startNodes=startNodes)[0], []
    toProcess, _ = graph.dfsToProcess(startNodes=startNodes)
    dependencies, _ = graph.dfsOnFinish(startNodes=startNodes, dependenciesOnly=True)
    skipped = [n for n in dependencies if n.globalStatus == "SUCCESS" and n not in toProcess]
    return toProcess, skipped


def checkSubmittable(editor, mode: str, force: bool):
    graph = editor.graph
    if mode != LOCAL and mode not in meshroom.core.submitters:
        raise ToolError("UNKNOWN_SUBMITTER", f"Unknown mode {mode!r}: use 'local' or one of the submitters "
                        f"{sorted(meshroom.core.submitters)}")
    if force and mode != LOCAL:
        raise ToolError("UNSUPPORTED", "force=true is only supported for local computations")
    if not graph.filepath:
        raise ToolError("NEVER_SAVED", "The project was never saved: save it with meshroom_save_project and a "
                        "path first.")
    if not editor.undoStack.isClean():
        raise ToolError("UNSAVED_CHANGES", "The project has unsaved changes, which submitting would write to "
                        f"{graph.filepath}: save them with meshroom_save_project first (preferably as a new file).")
    if editor.isComputingLocally():
        raise ToolError("COMPUTING", "A local computation is running: wait for it or use meshroom_cancel.")
    checkTopLevelKeysKept(graph)


def startComputation(editor, mode: str, nodes, force: bool) -> List[str]:
    """ Start like the Compute or Submit buttons. Return the warnings; raise ToolError if Meshroom refuses. """
    graph = editor.graph
    warnings = []
    with LogCapture() as capture:
        try:
            if mode == LOCAL and force:  # UIGraph.execute, which cannot force the computation
                editor.save()
                editor.taskManager.compute(graph, nodes, forceCompute=True)
                editor.updateLockedUndoStack()
            elif mode == LOCAL:
                editor.execute(nodes)
            else:  # UIGraph.submit, with the requested submitter instead of the application's default
                editor.save()
                editor.undoStack.clear()
                editor.taskManager.submit(graph, mode, nodes, submitLabel=editor.submitLabel)
        except RuntimeWarning as e:  # Raised once the computation started: nodes with missing inputs are skipped
            warnings.append(str(e))
        except RuntimeError as e:
            raise ToolError("SUBMIT_REFUSED", str(e))
    errors = [line for line in capture.lines if not line.startswith("WARNING")]
    if errors:
        raise ToolError("SUBMIT_FAILED", " | ".join(errors))
    return warnings + capture.lines


def submissionEffects(graph, mode: str, jobDir) -> str:
    effects = (f"writes {graph.filepath} (as Compute does); the undo stack is locked during the computation"
               if mode == LOCAL else
               f"writes {graph.filepath} and clears the undo stack (as Submit does), then submits to '{mode}'")
    if jobDir:
        effects += (f"; the project's cache moves to {jobDir}/{meshroom.core.cacheFolderName} (saved in the project "
                    f"file, not undoable) and a provenance manifest is written in {jobDir}")
    return effects


def submit(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    nodes = findNodes(graph, arguments.get("nodes"))
    mode, force = arguments.get("mode", LOCAL), arguments.get("force", False)
    checkSubmittable(editor, mode, force)
    jobDir = pipeline.checkJobDir(session, arguments["jobDir"]) if arguments.get("jobDir") else None
    if not arguments.get("confirm"):
        plan, skipped = submissionPlan(graph, nodes, force)
        return {"confirmRequired": True, "change": "Nothing started: call again with confirm=true to start",
                "mode": mode, "nodesToProcess": [n.name for n in plan], "skipped": skippedNodes(skipped),
                "effects": submissionEffects(graph, mode, jobDir),
                **({"note": "With jobDir, the statuses are those of the job folder's cache"} if jobDir else {})}
    job = pipeline.prepareJobDir(session, editor, jobDir) if jobDir else None
    ending = None
    try:
        plan, skipped = submissionPlan(graph, nodes, force)
        if not plan:
            raise ToolError("ALREADY_COMPUTED", f"Nothing to compute: {[n.name for n in skipped]} are already computed "
                            "with their current parameters. Pass force=true to compute them again.")
        if job and mode == LOCAL:  # Listen before starting: a short computation may end at once
            ending = background.NextEmission(editor.taskManager.computeFinished,
                                             lambda: pipeline.writeFinalManifest(session, editor, job["folder"]),
                                             parent=editor)
        warnings = startComputation(editor, mode, nodes, force)
    except ToolError:
        if ending:
            ending.cancel()
        if job:
            pipeline.restoreCacheDir(editor, job)
        raise
    data = {"change": f"Started ({mode}): poll meshroom_get_status for the result", "mode": mode,
            "nodesToProcess": [n.name for n in plan], "skipped": skippedNodes(skipped),
            "effects": submissionEffects(graph, mode, jobDir), "warnings": warnings,
            "nodes": [nodeStatus(n) for n in plan], **computationState(editor), **editState(editor)}
    if job:
        data["jobDir"] = job["folder"]
        data.update(pipeline.writeJobManifest(session, editor, job))
        pipeline.registerJob(job, graph, [n.name for n in plan], mode)
        data["finalManifest"] = ("written when the computation ends" if mode == LOCAL else
                                 "written by the first meshroom_get_status finding the job ended")
    return data


def skippedNodes(nodes) -> list:
    return [{"name": n.name, "uid": n._uid} for n in nodes]


# Monitoring

def refreshFromCache(node) -> bool:
    """
    For a node computed by a submitter, whose statuses are written by another process, read its status files as
    the UI's NodeStatusMonitor does. Return whether the status comes from the cache.
    """
    if node.globalExecMode != "EXTERN":
        return False
    if node.chunksCreated:
        for chunk in node.getAllChunks():
            chunk.updateStatusFromCache()
    else:
        node.updateStatusFromCache()
    if node.globalStatus == "SUCCESS":
        node.loadOutputAttr()
    return True


def finalizeFarmJobs(session: Session, editor):
    """ Write the final manifest of the submitter jobs found ended, after reading their nodes' status files. """
    for job in pipeline.pendingJobs():
        if job["mode"] == LOCAL or job["graph"] is not editor.graph:
            continue
        nodes = [editor.graph.node(name) for name in job["nodes"]]
        nodes = [n for n in nodes if n is not None]
        for node in nodes:
            refreshFromCache(node)
        if all(n.globalStatus in FINAL_STATUSES for n in nodes):
            pipeline.writeFinalManifest(session, editor, job["folder"])


def getStatus(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    nodes = findNodes(graph, arguments.get("nodes")) or [n for n in graph.nodes if not n.isBackdropNode]
    sources = ["cache" if refreshFromCache(n) else "memory" for n in nodes]
    finalizeFarmJobs(session, editor)
    if "cache" in sources:
        editor.updateGraphComputingStatus()
    statuses = [{**nodeStatus(n), "statusSource": source} for n, source in zip(nodes, sources)]
    counts = {}
    for status in statuses:
        counts[status["status"]] = counts.get(status["status"], 0) + 1
    data = {**computationState(editor), "statusCounts": counts}
    manifests, jobs = pipeline.manifestStates(), pipeline.jobStates()
    if manifests:
        data["manifests"] = manifests
    if jobs:
        data["jobs"] = jobs
    addList(data, "nodes", statuses)
    return data


def tail(path: str, maxLines: int, maxBytes: int) -> dict:
    """ The end of a text file, bounded in lines and bytes. """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - maxBytes))
            content = f.read(maxBytes)
    except OSError:
        return {"path": path, "exists": False}
    lines = content.decode("utf-8", errors="replace").splitlines()
    cutInBytes = size > maxBytes
    if cutInBytes and lines:
        lines = lines[1:]  # Partial first line
    cutInLines = len(lines) > maxLines
    lines = lines[len(lines) - maxLines:] if cutInLines else lines
    return {"path": path, "exists": True, "size": size, "truncated": cutInBytes or cutInLines, "text": "\n".join(lines)}


def boundedInteger(arguments, name, default, maximum) -> int:
    value = arguments.get(name, default)
    if not 1 <= value <= maximum:
        raise ToolError("INVALID_ARGUMENT", f"'{name}' must be between 1 and {maximum}")
    return value


def getLogs(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    node = findNode(editor.graph, arguments["node"])
    maxLines = boundedInteger(arguments, "maxLines", 200, MAX_LOG_LINES)
    maxBytes = boundedInteger(arguments, "maxBytes", 32 * 1024, MAX_LOG_BYTES)
    chunks = list(node.chunks) if node.chunksCreated else []
    if not chunks:
        raise ToolError("NO_LOGS", f"{node.name} has no chunks yet: it was never computed in this session or on disk.")
    if "chunk" in arguments:
        index = arguments["chunk"]
        if not 0 <= index < len(chunks):
            raise ToolError("INVALID_ARGUMENT", f"'chunk' must be between 0 and {len(chunks) - 1}")
        chunks = [chunks[index]]
    # The limits apply to the whole result: split them between the chunks
    linesPerChunk, bytesPerChunk = max(1, maxLines // len(chunks)), max(1, maxBytes // len(chunks))
    logs = [{"chunk": c.chunkIndex, "status": c.status.status.name, **tail(c.logFile, linesPerChunk, bytesPerChunk)}
            for c in chunks]
    return {"node": node.name, "status": node.globalStatus, "logs": logs}


# Cancelling

def runningChunks(graph) -> list:
    return [c for n in graph.nodes if n.chunksCreated for c in n.chunks if c.status.status.name in ("RUNNING", "SUBMITTED")]


def cancel(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    editor.updateGraphComputingStatus()
    if not editor.isComputingLocally():
        if editor.isComputingExternally():
            raise ToolError("NOT_LOCAL", "The computation runs on a render farm: cancel it from the farm manager.")
        return {"change": "Nothing to cancel: no local computation is running", **computationState(editor)}
    chunks = runningChunks(graph)
    nodes = list(dict.fromkeys(c.node for c in chunks))
    start = time.monotonic()
    with LogCapture() as capture:
        editor.stopExecution()  # Stop button: kills the running processes and waits for the computing thread
    blocked = time.monotonic() - start
    editor.updateGraphComputingStatus()
    # Verify: statuses after the stop, and processes Meshroom started that would still be alive
    aliveProcesses = [c.node.name for c in chunks if getattr(c, "subprocess", None) and c.subprocess.is_running()]
    data = {
        "change": f"Stopped the local computation of {len(nodes)} nodes",
        "blockedSeconds": round(blocked, 3),
        "nodes": [nodeStatus(n) for n in nodes],
        "processesStillAlive": aliveProcesses,
        "log": capture.lines,
        **computationState(editor),
    }
    if aliveProcesses or editor.isComputingLocally():
        raise ToolError("CANCEL_INCOMPLETE", f"After the stop: {data}")
    return data


# Outputs

def getOutputs(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    nodes = findNodes(graph, arguments.get("nodes")) or [n for n in graph.nodes if not n.isBackdropNode]
    result = []
    for node in nodes:
        outputs = []
        for attribute in node.attributes:
            if not attribute.isOutput or not attribute.enabled:
                continue
            value = attribute.evalValue
            outputs.append({"name": attribute.name, "type": attribute.type, "value": value,
                            **outputFiles(attribute)})
        result.append({"name": node.name, "status": node.globalStatus, "outputs": outputs})
    data = {}
    addList(data, "nodes", result)
    return data


# Declarations

def createExecutionTools(session: Session) -> List[Tool]:
    def bind(function):
        return lambda arguments: function(session, arguments)

    nodeList = {"type": "array", "items": {"type": "string"}, "description": "Node names; all the nodes by default"}
    return [
        makeTool("meshroom_submit",
                 "COSTLY: start computing the open project, locally (as the Compute button) or on a render farm "
                 "submitter, up to 'nodes' (all the leaves by default). It writes the project file (.mg); submitting "
                 "to a farm also clears the undo stack. Refused if the project has unsaved changes or was never "
                 "saved. Nodes already computed with the same parameters (same UID) are skipped and listed; "
                 "ALREADY_COMPUTED if nothing is left, unless force=true. With 'jobDir', the project's cache moves "
                 "there and a provenance manifest is written in it. Without confirm=true, only describes what would "
                 "run. Returns once started: poll meshroom_get_status for the result.",
                 {"type": "object", "additionalProperties": False, "properties": {
                     "nodes": nodeList,
                     "mode": {"type": "string", "description": "'local' (default) or a submitter name"},
                     "jobDir": {"type": "string", "description": "Job folder inside an output root: receives the "
                                "project's cache and a provenance manifest"},
                     "force": {"type": "boolean", "description": "Compute again the nodes already computed with "
                               "the same parameters (local only)"},
                     "confirm": {"type": "boolean", "description": "Required to actually start"},
                 }},
                 bind(submit)),
        makeTool("meshroom_get_status",
                 "Computation status of nodes and of their chunks as Meshroom exposes them (status, execution "
                 "mode, elapsed time, start/end, host), and whether a computation is running. 'statusSource' tells "
                 "where it comes from: 'memory' for local computations, 'cache' for submitter jobs, whose status "
                 "files are read again first. Meshroom gives no progress percentage.",
                 {"type": "object", "additionalProperties": False, "properties": {"nodes": nodeList}},
                 bind(getStatus)),
        makeTool("meshroom_get_logs",
                 "End of the log files of a node's chunks (one chunk with 'chunk'), bounded by 'maxLines' and "
                 "'maxBytes' for the whole result, with the log file paths. Read-only.",
                 {"type": "object", "additionalProperties": False, "required": ["node"], "properties": {
                     "node": {"type": "string", "description": "Node name"},
                     "chunk": {"type": "integer", "description": "Chunk index; all chunks by default"},
                     "maxLines": {"type": "integer", "description": f"Default 200, at most {MAX_LOG_LINES}"},
                     "maxBytes": {"type": "integer", "description": f"Default 32768, at most {MAX_LOG_BYTES}"},
                 }},
                 bind(getLogs)),
        makeTool("meshroom_cancel",
                 "Stop the local computation, as the Stop button: kills the running processes and waits for them. "
                 "Returns the statuses checked after the stop and how long the application was blocked. A stopped "
                 "chunk ends STOPPED or ERROR, depending on when its process is killed. Results already computed "
                 "are kept. Farm jobs must be cancelled from the farm manager.",
                 {"type": "object", "additionalProperties": False, "properties": {}},
                 bind(cancel)),
        makeTool("meshroom_get_outputs",
                 "Output attributes of nodes with their resolved values. For files: 'pattern' (placeholders such "
                 "as <VIEW_ID> replaced by '*'), the number of files on disk that 'matches' it, and the number "
                 "'expected' when known (1 for a plain path, one per view of the upstream CameraInit nodes for "
                 "<VIEW_ID>, null otherwise). Read-only.",
                 {"type": "object", "additionalProperties": False, "properties": {"nodes": nodeList}},
                 bind(getOutputs)),
    ]
