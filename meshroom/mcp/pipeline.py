"""
Production pipeline conventions on top of the MCP tools: provenance manifests and job folders.

The policies (what a manifest records, where job data goes, which folders may receive outputs) live here, not in
the tools adapting Meshroom (editing, execution).
"""
import datetime
import hashlib
import json
import os
import subprocess
import time
from typing import Dict, List

import meshroom
import meshroom.core
from meshroom.core import cacheFolderName
from meshroom.core.attribute import GroupAttribute, ListAttribute
from meshroom.mcp import security
from meshroom.mcp.rpc import Tool
from meshroom.mcp.tools import Session, ToolError, aliceVisionVersion, makeTool, outputFiles

MANIFEST_VERSION = 1
MANIFEST_EXTENSION = ".json"

FINAL_MANIFEST = "manifest.final.json"

# Submissions with a job folder, waiting for their final manifest: {folder: {"folder", "mode", "nodes", "graph", "final"}}
# ponytail: process-wide registry, never pruned; prune it if many jobs are submitted in one session
_jobs: Dict[str, dict] = {}

# Manifests whose source hashes are computed in the background: {path: {"manifest", "hashes", "token"}}
# ponytail: process-wide registry, never pruned; prune it if many manifests are written in one session
_hashing: Dict[str, dict] = {}


# Paths

def outputPath(session: Session, path: str, isFolder: bool = False, create: bool = True) -> str:
    """ Canonical 'path' if it is inside an output root. A folder is created unless 'create' is False. """
    roots = security.validRoots(session.getOutputRoots())
    if not roots:
        raise ToolError("NO_OUTPUT_ROOTS", "No valid output roots are configured: set the 'MCP/outputRoots' setting "
                        "of Meshroom to the folders job data and manifests may be written to.")
    if not os.path.isabs(path):
        raise ToolError("INVALID_PATH", f"Expected an absolute path, got {path!r}")
    parent = os.path.realpath(os.path.dirname(os.path.normpath(path)))
    resolved = os.path.join(parent, os.path.basename(os.path.normpath(path)))
    if not any(security.isUnder(resolved, r) and resolved != r for r in roots):
        raise ToolError("PATH_OUTSIDE_ROOTS", f"{path!r} is not inside an output root {roots}")
    if os.path.islink(resolved):
        raise ToolError("INVALID_PATH", f"{path!r} is a symbolic link")
    if isFolder:
        if create:
            os.makedirs(resolved, exist_ok=True)
    elif not os.path.isdir(parent):
        raise ToolError("INVALID_PATH", f"Folder {os.path.dirname(path)!r} does not exist")
    return resolved


# Provenance

def meshroomRevision() -> dict:
    """ Meshroom version, and its Git revision when it runs from a Git checkout. """
    root = os.path.dirname(os.path.dirname(os.path.abspath(meshroom.__file__)))
    result = {"version": meshroom.__version__, "label": meshroom.__version_label__, "source": "version"}
    try:
        def git(*args):
            return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, timeout=5,
                                  check=True).stdout.strip()
        result.update({"revision": git("rev-parse", "HEAD"),
                       "localChanges": bool(git("status", "--porcelain", "--untracked-files=no")), "source": "git"})
    except (OSError, subprocess.SubprocessError):
        pass  # Not a Git checkout, or no git: the version is the only provenance
    return result


def inputFiles(attribute):
    """ (attribute, path) of the File attributes in 'attribute' and in its children, if not connected. """
    if attribute.isLink or not attribute.enabled:
        return
    if isinstance(attribute, ListAttribute):
        for child in attribute:
            yield from inputFiles(child)
    elif isinstance(attribute, GroupAttribute):
        for child in attribute.value.values():
            yield from inputFiles(child)
    elif attribute.type == "File":
        path = attribute.evalValue
        if isinstance(path, str) and path:
            yield attribute, path


def sourceFiles(graph) -> List[dict]:
    """
    Files the project reads from outside of it: the unconnected input File attributes of all the nodes.
    'kind' is "view" for the images of CameraInit nodes, "file" otherwise.
    """
    sources = {}
    for node in graph.nodes:
        for root in node.attributes:
            if not root.isInput:
                continue
            for attribute, path in inputFiles(root):
                isView = node.nodeType == "CameraInit" and root.name == "viewpoints"
                source = sources.setdefault(path, {"path": path, "kind": "file", "attributes": []})
                source["attributes"].append(attribute.fullName)
                if isView:
                    source["kind"] = "view"
    return sorted(sources.values(), key=lambda s: (s["kind"] != "view", s["path"]))


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def hashFiles(paths: List[str]) -> Dict[str, str]:
    """ SHA-256 of files. Runs in a background thread: plain paths only, no Meshroom object. """
    return {path: sha256(path) for path in paths}


def sources(graph, hashImages: bool, hashLimit: int) -> dict:
    """ Source files with their sizes. 'hashes': skipped, overLimit, or pending (computed later, in the background). """
    files = sourceFiles(graph)
    for f in files:
        if os.path.isdir(f["path"]):
            f["isFolder"] = True
        elif os.path.isfile(f["path"]):
            f["size"] = os.path.getsize(f["path"])
        else:
            f["exists"] = False
    totalSize = sum(f.get("size", 0) for f in files)
    result = {"count": len(files), "totalSize": totalSize, "hashes": "pending", "files": files}
    if not hashImages:
        result["hashes"] = "skipped"
    elif totalSize > hashLimit:
        result["hashes"] = "overLimit"
        result["note"] = f"Not hashed: {totalSize} bytes in total, over the limit of {hashLimit} (MCP/manifestHashLimit)"
    return result


def nodeProvenance(node) -> dict:
    version = str(node.version) if node.isCompatibilityNode else meshroom.core.nodeVersion(type(node.nodeDesc))
    outputs = []
    for attribute in node.attributes:
        if attribute.isOutput and attribute.enabled:
            outputs.append({"name": attribute.name, "value": attribute.evalValue, **outputFiles(attribute)})
    return {
        "name": node.name,
        "nodeType": node.nodeType,
        "version": version,
        "uid": node._uid,
        "parameters": node.toDict().get("inputs", {}),
        "status": node.globalStatus,
        "execMode": node.globalExecMode,
        "outputs": outputs,
    }


def manifest(graph, unsavedChanges: bool, hashImages: bool = False, hashLimit: int = 0) -> dict:
    return {
        "manifestVersion": MANIFEST_VERSION,
        "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "project": {"path": graph.filepath or None, "unsavedChanges": unsavedChanges, "cacheDir": graph.cacheDir or None},
        "meshroom": meshroomRevision(),
        "aliceVision": aliceVisionVersion(),
        "nodes": [nodeProvenance(n) for n in graph.nodes if not n.isBackdropNode],
        "sources": sources(graph, hashImages, hashLimit),
    }


def writeJson(path: str, data: dict):
    """ Write atomically: readers never see a partial file. """
    temporary = f"{path}.writing"
    with open(temporary, "w") as f:
        json.dump(data, f, indent=2, default=str)
    os.replace(temporary, path)


def startHashing(session: Session, path: str, data: dict):
    """ Hash the source files of the manifest 'data' in the background, then write it again with the hashes. """
    token = object()  # A manifest written again at the same path meanwhile supersedes this one
    _hashing[path] = {"manifest": path, "hashes": "pending", "token": token}
    images = data["sources"]
    paths = [f["path"] for f in images["files"] if "size" in f]
    start = time.monotonic()

    def done(result):
        state = _hashing.get(path)
        if state is None or state["token"] is not token:
            return
        if isinstance(result, Exception):
            images.update({"hashes": "failed", "error": f"{type(result).__name__}: {result}"})
        else:
            for f in images["files"]:
                if f["path"] in result:
                    f["sha256"] = result[f["path"]]
            images.update({"hashes": "done", "hashSeconds": round(time.monotonic() - start, 3)})
        try:
            writeJson(path, data)
        except OSError as e:
            images.update({"hashes": "failed", "error": f"Cannot write {path}: {e}"})
        state["hashes"] = images["hashes"]
    session.runInBackground(lambda: hashFiles(paths), done)


def manifestStates() -> List[dict]:
    """ Manifests whose hashes are computed in the background, and their state: pending, done or failed. """
    return [{"manifest": s["manifest"], "hashes": s["hashes"]} for s in _hashing.values()]


def writeManifestFile(session: Session, editor, path: str, hashImages: bool = False) -> dict:
    data = manifest(editor.graph, not editor.undoStack.isClean(), hashImages, session.getManifestHashLimit())
    _hashing.pop(path, None)  # Supersedes a previous manifest still being hashed
    writeJson(path, data)
    images = data["sources"]
    if images["hashes"] == "pending":
        startHashing(session, path, data)
    return {"manifest": path, "nodes": len(data["nodes"]), "sources": images["count"],
            "hashes": _hashing[path]["hashes"] if path in _hashing else images["hashes"]}


def writeManifest(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    path = arguments["path"]
    if not path.endswith(MANIFEST_EXTENSION):
        raise ToolError("INVALID_PATH", f"Expected a '{MANIFEST_EXTENSION}' file, got {path!r}")
    target = outputPath(session, path)
    if os.path.exists(target) and not arguments.get("overwrite"):
        raise ToolError("FILE_EXISTS", f"{path!r} already exists: pass overwrite=true to replace it")
    result = writeManifestFile(session, editor, target, arguments.get("hashImages", False))
    return {"change": f"Wrote the provenance manifest {target}", **result}


# Job folders

def checkJobDir(session: Session, jobDir: str) -> str:
    """ Canonical job folder, without creating it. """
    return outputPath(session, jobDir, isFolder=True, create=False)


def prepareJobDir(session: Session, editor, jobDir: str) -> dict:
    """
    Use 'jobDir' for a submission: the project's cache moves to <jobDir>/MeshroomCache, through Meshroom's explicit
    cache folder (saved in the project file). Return what is needed to restore the previous cache folder.
    """
    folder = outputPath(session, jobDir, isFolder=True)
    graph = editor.graph
    # Graph has no public accessor for whether its cache folder is explicit
    previous = {"explicit": graph._hasExplicitCacheDir, "relative": graph._relativeCacheDir}
    graph.setExplicitCacheDir(os.path.join(folder, cacheFolderName))
    return {"folder": folder, "previous": previous}


def restoreCacheDir(editor, job: dict):
    graph = editor.graph
    if job["previous"]["explicit"]:
        graph.setExplicitCacheDir(job["previous"]["relative"])
    else:
        graph.setDefaultCacheDir()


def writeJobManifest(session: Session, editor, job: dict) -> dict:
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return writeManifestFile(session, editor, os.path.join(job["folder"], f"manifest-{stamp}{MANIFEST_EXTENSION}"))


def registerJob(job: dict, graph, nodes: List[str], mode: str):
    """ Record a started submission, whose final manifest is written once it ends. """
    _jobs[job["folder"]] = {"folder": job["folder"], "mode": mode, "nodes": nodes, "graph": graph, "final": None}


def pendingJobs() -> List[dict]:
    """ Jobs whose final manifest is not written yet. """
    return [j for j in _jobs.values() if not j["final"]]


def writeFinalManifest(session: Session, editor, folder: str):
    """ Write <folder>/manifest.final.json once a job has ended. Idempotent. """
    job = _jobs.get(folder)
    if not job or job["final"]:
        return
    if editor.graph is not job["graph"]:
        job["final"] = "abandoned: another project was opened before the job ended"
        return
    path = os.path.join(folder, FINAL_MANIFEST)
    writeManifestFile(session, editor, path)
    job["final"] = path


def jobStates() -> List[dict]:
    return [{"jobDir": j["folder"], "mode": j["mode"], "finalManifest": j["final"]} for j in _jobs.values()]


def createPipelineTools(session: Session) -> List[Tool]:
    return [
        makeTool("meshroom_write_manifest",
                 "Write a JSON provenance manifest of the open project: Meshroom version and Git revision, AliceVision "
                 "version and its source; for each node its type, version, parameters, UID, status and output paths; "
                 "its sources: the files read by the unconnected input File attributes of all the nodes ('kind': "
                 "\"view\" for CameraInit images, \"file\" otherwise), with their sizes. With hashImages=true, "
                 "their SHA-256 too, when they weigh less "
                 "than the 'MCP/manifestHashLimit' setting (1 GiB by default) in total: the manifest is written with "
                 "\"hashes\": \"pending\", then again once the background hashing ends (state in "
                 "meshroom_get_status). The path must be inside an output root of the 'MCP/outputRoots' setting.",
                 {"type": "object", "additionalProperties": False, "required": ["path"], "properties": {
                     "path": {"type": "string", "description": "Absolute path of the .json manifest"},
                     "hashImages": {"type": "boolean", "description": "Hash the source files (default false)"},
                     "overwrite": {"type": "boolean", "description": "Allow replacing an existing file"},
                 }},
                 lambda arguments: writeManifest(session, arguments)),
    ]
