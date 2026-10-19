"""
Execution tools on a real UIGraph and TaskManager, computing locally.

Like test_mcpEditing, they need the PySide backend: the test suite runs this file again in a subprocess.
AppendText (tests/nodes) always fails when computed: its command line uses '>' and '&&', and Meshroom runs it
without a shell. It serves the error and cancel cases; WriteText, below, the successful one.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

import pytest

import meshroom.common
from meshroom.core import desc

FIXTURE = os.path.join(os.path.dirname(__file__), "appendTextAndFiles.mg")
PYSIDE_BACKEND = meshroom.common.BaseObject.__module__ != "meshroom.common.core"
SUBPROCESS_FLAG = "MESHROOM_MCP_EXECUTION_SUBPROCESS"


@pytest.mark.skipif(PYSIDE_BACKEND or os.environ.get(SUBPROCESS_FLAG) == "1",
                    reason="Already running with the PySide backend")
def test_executionWithThePySideBackend():
    runner = ("import sys, meshroom; from meshroom.common import Backend; "
              "meshroom.setupEnvironment(backend=Backend.PYSIDE); "
              "import pytest; sys.exit(pytest.main(sys.argv[1:]))")
    result = subprocess.run([sys.executable, "-c", runner, __file__, "-q", "-p", "no:cacheprovider"],
                            cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            env=dict(os.environ, **{SUBPROCESS_FLAG: "1"}),
                            capture_output=True, text=True, timeout=600)
    assert result.returncode == 0, result.stdout[-5000:] + result.stderr[-5000:]


pyside = pytest.mark.skipif(not PYSIDE_BACKEND, reason="Runs in a subprocess with the PySide backend")


class WriteText(desc.BaseNode):
    """ Computed in the Meshroom process: writes its input text to its output file. """
    inputs = [desc.StringParam(name="text", label="Text", description="", value="hello")]
    outputs = [desc.File(name="output", label="Output", description="", value="{nodeCacheFolder}/text.txt")]

    def processChunk(self, chunk):
        with open(chunk.node.output.value, "w") as f:
            f.write(chunk.node.text.value)


def waitFor(condition, timeout=30.0):
    from PySide6.QtCore import QCoreApplication
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        QCoreApplication.processEvents()
        if condition():
            return True
        time.sleep(0.01)
    return False


@pytest.fixture
def workDir():
    # Short path: the cache folder holds deep paths, and the FIFO must be on a local file system
    path = tempfile.mkdtemp(prefix="mrx-", dir=os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
    yield path
    shutil.rmtree(path, ignore_errors=True)


@pytest.fixture
def editor(workDir):
    from PySide6.QtCore import QCoreApplication
    from meshroom.core.graph import loadGraph
    from meshroom.core.taskManager import TaskManager
    from meshroom.ui import commands
    from meshroom.ui.graph import UIGraph
    from tests.utils import registeredNodeTypes
    QCoreApplication.instance() or QCoreApplication([])
    with registeredNodeTypes([WriteText]):
        uiGraph = UIGraph(commands.UndoStack(), TaskManager())
        uiGraph.setGraph(loadGraph(FIXTURE))
        inputFile = os.path.join(workDir, "input.txt")
        with open(inputFile, "w") as f:
            f.write("input\n")
        for name in ("AppendText_1", "AppendText_2"):
            uiGraph.graph.attribute(f"{name}.input").value = inputFile
        uiGraph.saveAs(os.path.join(workDir, "project.mg"))
        yield uiGraph
        uiGraph.stopExecution()
        uiGraph.stopChildThreads()
        uiGraph._taskManager.join()
        uiGraph.clear()  # Destroy the nodes while the TaskManager, which watches them, still exists


@pytest.fixture
def outputRoot(workDir):
    path = os.path.join(workDir, "out")
    os.mkdir(path)
    return path


@pytest.fixture
def hashLimit():
    return [1 << 30]  # Changed by the tests: the session reads it at each call


@pytest.fixture
def call(editor, outputRoot, hashLimit):
    from meshroom.mcp.background import BackgroundTasks
    from meshroom.mcp.execution import createExecutionTools
    from meshroom.mcp.pipeline import createPipelineTools
    from meshroom.mcp.tools import Session
    background = BackgroundTasks()
    session = Session(lambda: editor.graph, lambda: [], getEditor=lambda: editor, getOutputRoots=lambda: [outputRoot],
                      runInBackground=background.run, getManifestHashLimit=lambda: hashLimit[0])
    tools = {t.name: t for t in createExecutionTools(session) + createPipelineTools(session)}

    def callTool(name, **arguments):
        result = tools[name].handler(arguments)
        return json.loads(result["content"][0]["text"]), result["isError"]
    return callTool


def finished(editor, name):
    editor.updateChunks()
    return editor.graph.node(name).globalStatus in ("SUCCESS", "ERROR", "STOPPED", "KILLED") \
        and not editor._taskManager._thread.isRunning()


@pyside
def test_submitRefusals(editor, call):
    data, isError = call("meshroom_submit", nodes=["AppendText_1"], mode="noSuchFarm", confirm=True)
    assert isError and data["error"] == "UNKNOWN_SUBMITTER"
    data, isError = call("meshroom_submit", nodes=["Nope_1"], confirm=True)
    assert isError and data["error"] == "NODE_NOT_FOUND"
    editor.setAttribute(editor.graph.attribute("AppendText_1.inputText"), "unsaved")
    mtime = os.path.getmtime(editor.graph.filepath)
    data, isError = call("meshroom_submit", nodes=["AppendText_1"], confirm=True)
    assert isError and data["error"] == "UNSAVED_CHANGES"
    assert os.path.getmtime(editor.graph.filepath) == mtime and editor.graph.node("AppendText_1").globalStatus == "NONE"


@pyside
def test_submitWithoutConfirmOnlyDescribes(editor, call):
    mtime = os.path.getmtime(editor.graph.filepath)
    data, isError = call("meshroom_submit")
    assert not isError and data["confirmRequired"]
    assert sorted(data["nodesToProcess"]) == ["AppendFiles_1", "AppendText_1", "AppendText_2"]
    assert "writes" in data["effects"]
    assert os.path.getmtime(editor.graph.filepath) == mtime
    assert all(n.globalStatus == "NONE" for n in editor.graph.nodes)


@pyside
def test_localErrorTransitionsAndLogs(editor, call):
    data, isError = call("meshroom_submit", nodes=["AppendText_1"], confirm=True)
    assert not isError and data["nodesToProcess"] == ["AppendText_1"]
    seen = [data["nodes"][0]["status"]]

    def observe():
        status = call("meshroom_get_status", nodes=["AppendText_1"])[0]["nodes"][0]["status"]
        if status != seen[-1]:
            seen.append(status)
        return finished(editor, "AppendText_1")
    assert waitFor(observe)
    observe()
    assert seen[0] == "SUBMITTED" and seen[-1] == "ERROR", seen
    status, _ = call("meshroom_get_status", nodes=["AppendText_1"])
    chunk = status["nodes"][0]["chunks"][0]
    assert chunk["status"] == "ERROR" and chunk["execMode"] == "LOCAL" and chunk["endDateTime"]
    assert "percent" not in json.dumps(status).lower()

    logs, isError = call("meshroom_get_logs", node="AppendText_1")
    assert not isError and logs["logs"][0]["exists"] and "No such file or directory" in logs["logs"][0]["text"]
    short, _ = call("meshroom_get_logs", node="AppendText_1", chunk=0, maxLines=2)
    assert short["logs"][0]["truncated"] and len(short["logs"][0]["text"].splitlines()) == 2
    tiny, _ = call("meshroom_get_logs", node="AppendText_1", maxBytes=40)
    assert tiny["logs"][0]["truncated"] and len(tiny["logs"][0]["text"].encode()) <= 40
    neverComputed, isError = call("meshroom_get_logs", node="AppendText_2")
    assert not isError and neverComputed["logs"][0]["exists"] is False and neverComputed["logs"][0]["path"]
    for arguments, code in [({"node": "AppendText_1", "chunk": 3}, "INVALID_ARGUMENT"),
                            ({"node": "AppendText_1", "maxLines": 0}, "INVALID_ARGUMENT")]:
        data, isError = call("meshroom_get_logs", **arguments)
        assert isError and data["error"] == code, (arguments, data)


@pyside
def test_localSuccessAndOutputs(editor, call):
    node = editor.addNewNode("WriteText")
    editor.save()
    outputs, _ = call("meshroom_get_outputs", nodes=[node.name])
    output = outputs["nodes"][0]["outputs"][0]
    assert output["pattern"] == output["value"] and output["matches"] == 0 and output["expected"] == 1
    data, isError = call("meshroom_submit", nodes=[node.name], confirm=True)
    assert not isError
    assert waitFor(lambda: finished(editor, node.name))
    status, _ = call("meshroom_get_status", nodes=[node.name])
    assert status["nodes"][0]["status"] == "SUCCESS" and status["computingLocally"] is False
    outputs, _ = call("meshroom_get_outputs", nodes=[node.name])
    output = outputs["nodes"][0]["outputs"][0]
    assert output["matches"] == 1 and output["expected"] == 1 and open(output["value"]).read() == "hello"
    data, isError = call("meshroom_submit", nodes=[node.name], confirm=True)
    assert isError and data["error"] == "ALREADY_COMPUTED"


@pyside
def test_cancelDuringExecution(editor, call, workDir):
    fifo = os.path.join(workDir, "blocking.fifo")
    os.mkfifo(fifo)  # 'cat' blocks reading it: the chunk runs until it is stopped
    editor.graph.attribute("AppendText_1.input").value = fifo
    editor.save()
    data, isError = call("meshroom_submit", nodes=["AppendText_1"], confirm=True)
    assert not isError
    chunk = lambda: editor.graph.node("AppendText_1").chunks[0]  # noqa: E731
    assert waitFor(lambda: editor.graph.node("AppendText_1").chunksCreated and chunk().isRunning()
                   and getattr(chunk(), "subprocess", None) is not None)
    process = chunk().subprocess
    data, isError = call("meshroom_cancel")
    assert not isError, data
    assert data["blockedSeconds"] >= 0 and data["processesStillAlive"] == [] and not data["computingLocally"]
    assert data["nodes"][0]["name"] == "AppendText_1" and data["nodes"][0]["status"] in ("STOPPED", "ERROR", "KILLED")
    assert not process.is_running()
    data, isError = call("meshroom_cancel")
    assert not isError and data["change"].startswith("Nothing to cancel")


@pyside
def test_submitToANamedSubmitter(editor, call, monkeypatch):
    import meshroom.core
    from meshroom.core.submitter import BaseSubmitter
    submitted = []

    class FakeFarm(BaseSubmitter):
        _name = "fakeFarm"

        def submit(self, nodes, edges, filepath, submitLabel="{projectName}"):
            submitted.append(([n.name for n in nodes], filepath))
            return True
    monkeypatch.setitem(meshroom.core.submitters, "fakeFarm", FakeFarm())
    editor.setAttribute(editor.graph.attribute("AppendText_1.inputText"), "edited")
    editor.save()
    assert editor.undoStack.count() == 1
    data, isError = call("meshroom_submit", nodes=["AppendText_1"], mode="fakeFarm", confirm=True)
    assert not isError, data
    assert submitted == [(["AppendText_1"], editor.graph.filepath)]
    assert editor.undoStack.count() == 0  # As the Submit button
    assert data["nodes"][0]["execMode"] == "EXTERN" and data["nodes"][0]["status"] == "SUBMITTED"
    data, isError = call("meshroom_cancel")
    assert isError and data["error"] == "NOT_LOCAL"

    # The farm writes the status files: get_status reads them again, like the UI's monitor
    from meshroom.core.graph import loadGraph
    from meshroom.core.node import ExecMode, Status
    status, _ = call("meshroom_get_status", nodes=["AppendText_1", "AppendText_2"])
    assert [(n["status"], n["statusSource"]) for n in status["nodes"]] == [("SUBMITTED", "cache"), ("NONE", "memory")]
    farm = loadGraph(editor.graph.filepath)
    farm.node("AppendText_1").upgradeStatusTo(Status.SUCCESS, ExecMode.EXTERN)
    assert editor.graph.node("AppendText_1").globalStatus == "SUBMITTED"  # Memory is not updated by itself
    status, _ = call("meshroom_get_status", nodes=["AppendText_1"])
    node = status["nodes"][0]
    assert node["status"] == "SUCCESS" and node["statusSource"] == "cache" and node["execMode"] == "EXTERN"
    assert status["computingExternally"] is False


def computeAndWait(editor, call, node, **arguments):
    data, isError = call("meshroom_submit", nodes=[node.name], confirm=True, **arguments)
    assert not isError, data
    assert waitFor(lambda: finished(editor, node.name))
    return data


@pyside
def test_writeManifest(editor, call, outputRoot, workDir, hashLimit):
    import hashlib
    from tests.test_mcpEditing import CameraInit
    from tests.utils import registeredNodeTypes
    images = []
    for name, content in (("a.jpg", b"first image"), ("b.jpg", b"second")):
        images.append(os.path.join(workDir, name))
        with open(images[-1], "wb") as f:
            f.write(content)
    with registeredNodeTypes([CameraInit]):
        cameraInit = editor.addNewNode("CameraInit")
        cameraInit.viewpoints.value = [{"path": p} for p in images]  # Stand-in node: no image viewer involved
        editor.save()
        target = os.path.join(outputRoot, "manifest.json")
        for arguments, code in [({"path": os.path.join(workDir, "m.json")}, "PATH_OUTSIDE_ROOTS"),
                                ({"path": os.path.join(outputRoot, "m.txt")}, "INVALID_PATH"),
                                ({"path": os.path.join(outputRoot, "missing", "m.json")}, "INVALID_PATH")]:
            data, isError = call("meshroom_write_manifest", **arguments)
            assert isError and data["error"] == code, (arguments, data)

        # Default: no hashes
        data, isError = call("meshroom_write_manifest", path=target)
        assert not isError and data["manifest"] == target and data["hashes"] == "skipped"
        manifest = json.load(open(target))
        assert manifest["manifestVersion"] == 1 and manifest["project"]["path"] == editor.graph.filepath
        revision = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                                  cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))).stdout.strip()
        assert manifest["meshroom"]["source"] == "git" and manifest["meshroom"]["revision"] == revision
        assert "source" in manifest["aliceVision"]
        node = next(n for n in manifest["nodes"] if n["name"] == "AppendText_1")
        assert node["nodeType"] == "AppendText" and node["uid"] == editor.graph.node("AppendText_1")._uid
        assert node["parameters"]["inputText"] == "Input text from AppendText_1" and node["status"] == "NONE"
        assert node["outputs"][0]["name"] == "output" and node["outputs"][0]["matches"] == 0
        files = manifest["sources"]["files"]
        views = [f for f in files if f["kind"] == "view"]
        assert [f["path"] for f in views] == images and views[0]["size"] == 11
        assert views[0]["attributes"] == [f"{cameraInit.name}.viewpoints[0].path"]
        # The unconnected input File attributes of the other nodes, e.g. the input files of AppendText_1 and _2
        inputFile = next(f for f in files if f["path"] == editor.graph.node("AppendText_1").input.value)
        assert inputFile["kind"] == "file" and sorted(inputFile["attributes"]) == ["AppendText_1.input", "AppendText_2.input"]
        assert not any(a.startswith("AppendFiles_1.input") for f in files for a in f["attributes"])  # Connected
        assert not any("sha256" in f for f in files)

        # Hashes computed in the background, then the manifest is written again
        data, isError = call("meshroom_write_manifest", path=target, hashImages=True)
        assert isError and data["error"] == "FILE_EXISTS"
        data, isError = call("meshroom_write_manifest", path=target, hashImages=True, overwrite=True)
        assert not isError and data["hashes"] == "pending"
        assert json.load(open(target))["sources"]["hashes"] == "pending"
        assert {"manifest": target, "hashes": "pending"} in call("meshroom_get_status")[0]["manifests"]
        assert waitFor(lambda: json.load(open(target))["sources"]["hashes"] == "done")
        files = json.load(open(target))["sources"]["files"]
        assert files[0]["sha256"] == hashlib.sha256(b"first image").hexdigest()
        assert all("sha256" in f for f in files if "size" in f)
        assert {"manifest": target, "hashes": "done"} in call("meshroom_get_status")[0]["manifests"]

        # Over the limit: no hashing
        hashLimit[0] = 10
        data, isError = call("meshroom_write_manifest", path=target, hashImages=True, overwrite=True)
        sources = json.load(open(target))["sources"]
        assert data["hashes"] == "overLimit" and "note" in sources
        assert not any("sha256" in f for f in sources["files"])

        # A manifest written again while the previous one is hashed is not overwritten by the late hashes
        hashLimit[0] = 1 << 30
        call("meshroom_write_manifest", path=target, hashImages=True, overwrite=True)
        call("meshroom_write_manifest", path=target, overwrite=True)
        waitFor(lambda: False, timeout=0.5)
        assert json.load(open(target))["sources"]["hashes"] == "skipped"
        editor.removeNodes([cameraInit])


@pyside
def test_nextEmissionCallsBackInTheMainThread():
    from PySide6.QtCore import QCoreApplication, QObject, QThread, Signal
    from meshroom.mcp.background import NextEmission

    class Sender(QObject):
        signal = Signal()

    class Worker(QThread):
        def run(self):
            sender.signal.emit()
            sender.signal.emit()  # Only the first emission counts

    threads, owner, sender, worker = [], QObject(), Sender(), Worker()
    # Created in the main thread, as meshroom_submit does
    NextEmission(sender.signal, lambda: threads.append(QThread.currentThread()), owner)
    # The sender lives in the worker thread: a callable connected without receiver object would run there
    sender.moveToThread(worker)
    worker.start()
    worker.wait()
    assert waitFor(lambda: threads)
    QCoreApplication.processEvents()
    assert threads == [QCoreApplication.instance().thread()]


@pyside
def test_submitInAJobDir(editor, call, outputRoot, workDir, monkeypatch):
    from PySide6.QtCore import QThread
    from meshroom.mcp import pipeline
    writeFinalManifest, threads = pipeline.writeFinalManifest, []

    def recordThread(*args):
        threads.append(QThread.currentThread())
        return writeFinalManifest(*args)
    monkeypatch.setattr(pipeline, "writeFinalManifest", recordThread)
    node = editor.addNewNode("WriteText")
    editor.save()
    defaultCache = editor.graph.cacheDir
    data, isError = call("meshroom_submit", nodes=[node.name], jobDir=os.path.join(workDir, "job"), confirm=True)
    assert isError and data["error"] == "PATH_OUTSIDE_ROOTS" and editor.graph.cacheDir == defaultCache

    jobDir = os.path.join(outputRoot, "shot010", "job1")
    data, isError = call("meshroom_submit", nodes=[node.name], jobDir=jobDir)
    assert not isError and data["confirmRequired"] and "MeshroomCache" in data["effects"]
    assert not os.path.exists(jobDir) and editor.graph.cacheDir == defaultCache

    data = computeAndWait(editor, call, node, jobDir=jobDir)
    assert editor.graph.cacheDir == os.path.join(jobDir, "MeshroomCache")
    assert node.output.value.startswith(os.path.join(jobDir, "MeshroomCache"))
    assert json.load(open(editor.graph.filepath))["header"]["cacheDir"]["absoluteCacheDir"] == editor.graph.cacheDir
    manifest = json.load(open(data["manifest"]))
    assert os.path.dirname(data["manifest"]) == jobDir and data["jobDir"] == jobDir
    # Written once started: WriteText may already be running or computed
    assert next(n for n in manifest["nodes"] if n["name"] == node.name)["status"] in ("SUBMITTED", "RUNNING", "SUCCESS")

    # The final manifest is written when the TaskManager's thread ends
    final = os.path.join(jobDir, "manifest.final.json")
    assert waitFor(lambda: os.path.exists(final))
    assert next(n for n in json.load(open(final))["nodes"] if n["name"] == node.name)["status"] == "SUCCESS"
    assert threads == [editor.thread()]  # On computeFinished, in the main thread
    jobs = call("meshroom_get_status", nodes=[node.name])[0]["jobs"]
    assert {"jobDir": jobDir, "mode": "local", "finalManifest": final} in jobs


@pyside
def test_submitRestoresTheCacheWhenItFails(editor, call, outputRoot, monkeypatch):
    from meshroom.mcp import execution
    from meshroom.mcp.tools import ToolError
    node = editor.addNewNode("WriteText")
    editor.save()
    defaultCache = editor.graph.cacheDir

    def refuse(*args):
        raise ToolError("SUBMIT_REFUSED", "refused for the test")
    monkeypatch.setattr(execution, "startComputation", refuse)
    data, isError = call("meshroom_submit", nodes=[node.name], jobDir=os.path.join(outputRoot, "job"), confirm=True)
    assert isError and data["error"] == "SUBMIT_REFUSED"
    assert editor.graph.cacheDir == defaultCache


@pyside
def test_submitSkipsComputedNodesUnlessForced(editor, call):
    node = editor.addNewNode("WriteText")
    editor.save()
    computeAndWait(editor, call, node)
    output = node.output.value
    firstWrite = os.path.getmtime(output)

    data, isError = call("meshroom_submit", nodes=[node.name])
    assert not isError and data["nodesToProcess"] == []
    assert data["skipped"] == [{"name": node.name, "uid": node._uid}]
    data, isError = call("meshroom_submit", nodes=[node.name], confirm=True)
    assert isError and data["error"] == "ALREADY_COMPUTED" and node.name in data["message"]
    data, isError = call("meshroom_submit", nodes=[node.name], mode="anyFarm", force=True, confirm=True)
    assert isError and data["error"] in ("UNSUPPORTED", "UNKNOWN_SUBMITTER")

    time.sleep(0.01)
    data = computeAndWait(editor, call, node, force=True)
    assert data["nodesToProcess"] == [node.name] and data["skipped"] == []
    assert node.globalStatus == "SUCCESS" and os.path.getmtime(output) > firstWrite


@pyside
def test_farmJobFinalManifest(editor, call, outputRoot, monkeypatch):
    import meshroom.core
    from meshroom.core.graph import loadGraph
    from meshroom.core.node import ExecMode, Status
    from meshroom.core.submitter import BaseSubmitter

    class FakeFarm(BaseSubmitter):
        _name = "fakeFarm"

        def submit(self, nodes, edges, filepath, submitLabel="{projectName}"):
            return True
    monkeypatch.setitem(meshroom.core.submitters, "fakeFarm", FakeFarm())
    jobDir = os.path.join(outputRoot, "farmJob")
    data, isError = call("meshroom_submit", nodes=["AppendText_1"], mode="fakeFarm", jobDir=jobDir, confirm=True)
    assert not isError, data
    final = os.path.join(jobDir, "manifest.final.json")
    status, _ = call("meshroom_get_status", nodes=["AppendText_2"])
    assert not os.path.exists(final) and {"jobDir": jobDir, "mode": "fakeFarm", "finalManifest": None} in status["jobs"]

    # The farm ends the job, writing the status files: the next get_status writes the final manifest
    loadGraph(editor.graph.filepath).node("AppendText_1").upgradeStatusTo(Status.SUCCESS, ExecMode.EXTERN)
    status, _ = call("meshroom_get_status", nodes=["AppendText_2"])
    assert {"jobDir": jobDir, "mode": "fakeFarm", "finalManifest": final} in status["jobs"]
    node = next(n for n in json.load(open(final))["nodes"] if n["name"] == "AppendText_1")
    assert node["status"] == "SUCCESS" and node["execMode"] == "EXTERN"
