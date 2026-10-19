"""
Editing tools on a real UIGraph and undo stack.

They need the PySide backend of meshroom.common, which is chosen once per process: the test suite (standalone
backend) runs this file again in a subprocess with the PySide backend.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys

import pytest

import meshroom.common
from meshroom.core import desc

FIXTURE = os.path.join(os.path.dirname(__file__), "appendTextAndFiles.mg")
PYSIDE_BACKEND = meshroom.common.BaseObject.__module__ != "meshroom.common.core"
SUBPROCESS_FLAG = "MESHROOM_MCP_EDITING_SUBPROCESS"


@pytest.mark.skipif(PYSIDE_BACKEND or os.environ.get(SUBPROCESS_FLAG) == "1",
                    reason="Already running with the PySide backend")
def test_editingWithThePySideBackend():
    runner = ("import sys, meshroom; from meshroom.common import Backend; "
              "meshroom.setupEnvironment(backend=Backend.PYSIDE); "
              "import pytest; sys.exit(pytest.main(sys.argv[1:]))")
    result = subprocess.run([sys.executable, "-c", runner, __file__, "-q", "-p", "no:cacheprovider"],
                            cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            env=dict(os.environ, **{SUBPROCESS_FLAG: "1"}),
                            capture_output=True, text=True, timeout=600)
    assert result.returncode == 0, result.stdout[-5000:] + result.stderr[-5000:]


pyside = pytest.mark.skipif(not PYSIDE_BACKEND, reason="Runs in a subprocess with the PySide backend")


def fileHash(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


@pytest.fixture
def projectRoot(tmp_path):
    root = tmp_path / "projects"
    root.mkdir()
    return root


@pytest.fixture
def inputRoot(tmp_path):
    root = tmp_path / "inputs"
    root.mkdir()
    return root


class CameraInit(desc.Node):
    """ Stand-in for AliceVision's CameraInit (not loaded in the tests), with the attributes the tools check. """
    inputs = [
        desc.ListAttribute(name="viewpoints", label="Viewpoints", description="", elementDesc=desc.GroupAttribute(
            name="viewpoint", label="Viewpoint", description="",
            items=[desc.File(name="path", label="Path", description="", value="")])),
        desc.ListAttribute(name="intrinsics", label="Intrinsics", description="", elementDesc=desc.GroupAttribute(
            name="intrinsic", label="Intrinsic", description="",
            items=[desc.FloatParam(name="pxFocalLength", label="Focal", description="", value=0.0)])),
    ]
    outputs = [desc.File(name="output", label="Output", description="", value="{nodeCacheFolder}/cameraInit.sfm")]


@pytest.fixture
def editor():
    from PySide6.QtCore import QCoreApplication
    from meshroom.core.graph import loadGraph
    from meshroom.core.taskManager import TaskManager
    from meshroom.ui import commands
    from meshroom.ui.graph import UIGraph
    QCoreApplication.instance() or QCoreApplication([])
    uiGraph = UIGraph(commands.UndoStack(), TaskManager())
    uiGraph.setGraph(loadGraph(FIXTURE))
    yield uiGraph
    uiGraph.stopChildThreads()


@pytest.fixture
def call(editor, projectRoot, inputRoot):
    from meshroom.mcp.editing import createEditingTools
    from meshroom.mcp.tools import Session, createTools
    session = Session(lambda: editor.graph, lambda: [str(projectRoot)], getEditor=lambda: editor,
                      getInputRoots=lambda: [str(inputRoot)])
    tools = {t.name: t for t in createTools(session) + createEditingTools(session)}

    def callTool(name, **arguments):
        result = tools[name].handler(arguments)
        data = json.loads(result["content"][0]["text"])
        return data, result["isError"]
    return callTool


def snapshot(graph):
    return json.dumps(graph.toDict(), sort_keys=True, default=str)


@pyside
def test_cycleMutateUndoValidateSaveAsReload(editor, call, projectRoot):
    from meshroom.core.graph import loadGraph
    fixtureHash = fileHash(FIXTURE)
    graph = editor.graph
    initial = snapshot(graph)

    data, isError = call("meshroom_set_parameter", attribute="AppendText_1.inputText", value="Edited")
    assert not isError and data["dirty"] and data["previous"] == "Input text from AppendText_1"
    assert graph.attribute("AppendText_1.inputText").value == "Edited"
    data, isError = call("meshroom_add_node", node_type="AppendText", position={"x": 0, "y": 320})
    assert not isError
    added = data["node"]["name"]
    data, isError = call("meshroom_connect_nodes", source=f"{added}.output", destination="AppendFiles_1.input")
    assert not isError and data["replacedEdge"] == {"from": "AppendText_1.output", "to": "AppendFiles_1.input"}
    assert graph.edge(graph.attribute("AppendFiles_1.input")).src.node.name == added
    data, isError = call("meshroom_disconnect_nodes", destination="AppendFiles_1.input2")
    assert not isError and graph.edge(graph.attribute("AppendFiles_1.input2")) is None
    data, isError = call("meshroom_remove_node", node="AppendText_2")
    assert not isError and graph.node("AppendText_2") is None
    assert {"from": "AppendText_2.input", "to": "AppendFiles_1.input4"} in data["removedEdges"]
    assert snapshot(graph) != initial

    while editor.undoStack.canUndo:
        editor.undoStack.undo()
    assert snapshot(graph) == initial
    data, isError = call("meshroom_validate_graph")
    assert not isError and data["valid"]

    graph.attribute("AppendText_1.inputText").value = "Saved"
    target = projectRoot / "saved.mg"
    data, isError = call("meshroom_save_project", path=str(target))
    assert not isError and data["path"] == str(target) and data["dirty"] is False
    assert graph.filepath == str(target)
    reloaded = loadGraph(str(target))
    assert sorted(n.name for n in reloaded.nodes) == ["AppendFiles_1", "AppendText_1", "AppendText_2"]
    assert reloaded.attribute("AppendText_1.inputText").value == "Saved"
    assert reloaded.edge(reloaded.attribute("AppendFiles_1.input")).src.fullName == "AppendText_1.output"
    assert fileHash(FIXTURE) == fixtureHash


@pyside
def test_dryRunChangesNothing(editor, call, projectRoot):
    initial, index = snapshot(editor.graph), editor.undoStack.index
    for name, arguments in [
        ("meshroom_set_parameter", {"attribute": "AppendText_1.inputText", "value": "x"}),
        ("meshroom_add_node", {"node_type": "AppendText"}),
        ("meshroom_remove_node", {"node": "AppendText_2"}),
        ("meshroom_connect_nodes", {"source": "AppendText_2.output", "destination": "AppendFiles_1.input"}),
        ("meshroom_disconnect_nodes", {"destination": "AppendFiles_1.input"}),
        ("meshroom_save_project", {"path": str(projectRoot / "dry.mg")}),
    ]:
        data, isError = call(name, dry_run=True, **arguments)
        assert not isError and data["dryRun"] and data["change"].startswith("Would "), (name, data)
    assert snapshot(editor.graph) == initial and editor.undoStack.index == index
    assert not (projectRoot / "dry.mg").exists()


@pyside
@pytest.mark.parametrize("attribute, value, code", [
    ("AppendText_1.output", "/tmp/x", "OUTPUT_ATTRIBUTE"),
    ("AppendFiles_1.input", "x", "LINKED"),
    ("AppendText_1.inputText", 3, "INVALID_VALUE"),
    ("AppendText_1.inputText", "{AppendText_2.output}", "INVALID_VALUE"),
    ("AppendText_1.nope", "x", "ATTRIBUTE_NOT_FOUND"),
    ("Nope_1.input", "x", "NODE_NOT_FOUND"),
])
def test_setParameterRefusals(call, attribute, value, code):
    data, isError = call("meshroom_set_parameter", attribute=attribute, value=value)
    assert isError and data["error"] == code, data


@pyside
def test_setParameterListsAndGroups(editor, call):
    node = editor.addNewNode("GroupAttributes")
    name = node.name
    data, isError = call("meshroom_set_parameter", attribute=f"{name}.firstGroup.firstGroupIntA", value=5000)
    assert not isError and data["warnings"]  # Outside of the range: warning only
    data, isError = call("meshroom_set_parameter", attribute=f"{name}.firstGroup.singleGroupedList", value=[1, 2, 3])
    assert not isError and node.attribute("firstGroup.singleGroupedList").getSerializedValue() == [1, 2, 3]
    data, isError = call("meshroom_set_parameter", attribute=f"{name}.firstGroup.singleGroupedList[1]", value=20)
    assert not isError and node.attribute("firstGroup.singleGroupedList").getSerializedValue() == [1, 20, 3]
    data, isError = call("meshroom_set_parameter", attribute=f"{name}.firstGroup.nestedGroup",
                         value={"nestedGroupFloat": 2.5})
    assert not isError and node.attribute("firstGroup.nestedGroup.nestedGroupFloat").value == 2.5
    data, isError = call("meshroom_set_parameter", attribute=f"{name}.firstGroup.firstGroupChoiceParam",
                         value=["three"])
    assert not isError
    for attribute, value in [("firstGroup.singleGroupedList", [1, "2"]), ("firstGroup.singleGroupedList", 3),
                             ("firstGroup.nestedGroup", {"unknown": 1}), ("firstGroup.firstGroupIntA", 1.5),
                             ("firstGroup.firstGroupBool", 1), ("firstGroup.firstGroupExclusiveChoiceParam", "five"),
                             ("firstGroup.firstGroupChoiceParam", "one")]:
        data, isError = call("meshroom_set_parameter", attribute=f"{name}.{attribute}", value=value)
        assert isError and data["error"] == "INVALID_VALUE", (attribute, value, data)


@pyside
def test_keyableAttributeIsRefused(editor, call):
    node = editor.addNewNode("AllAttributesNode")
    index = editor.undoStack.index
    data, isError = call("meshroom_set_parameter", attribute=f"{node.name}.keyableFloat", value=1.0)
    assert isError and data["error"] == "KEYABLE_ATTRIBUTE", data
    assert editor.undoStack.index == index


@pyside
def test_lockedNodeIsRefusedBeforeRemoveNodes(editor, call, monkeypatch):
    calls = []
    monkeypatch.setattr(editor, "removeNodes", lambda nodes: calls.append(nodes))
    editor.graph.node("AppendText_2").locked = True
    for name, arguments in [("meshroom_remove_node", {"node": "AppendText_2"}),
                            ("meshroom_set_parameter", {"attribute": "AppendText_2.inputText", "value": "x"})]:
        data, isError = call(name, **arguments)
        assert isError and data["error"] == "NODE_LOCKED"
    assert calls == []


@pyside
@pytest.mark.parametrize("source, destination, code", [
    ("AppendFiles_1.output", "AppendText_1.input", "CYCLE"),
    ("AppendText_1.input", "AppendText_2.output", "INVALID_DIRECTION"),
    ("AppendText_1.output", "AppendFiles_1.nope", "ATTRIBUTE_NOT_FOUND"),
])
def test_connectRefusals(call, source, destination, code):
    data, isError = call("meshroom_connect_nodes", source=source, destination=destination)
    assert isError and data["error"] == code, data


@pyside
def test_connectIncompatibleTypes(editor, call):
    node = editor.addNewNode("GroupAttributes")
    data, isError = call("meshroom_connect_nodes", source=f"{node.name}.exposedInt", destination="AppendText_1.input")
    assert isError and data["error"] == "INCOMPATIBLE_TYPES", data


@pyside
def test_invalidEdgeErrorIsTranslatedAndReverted(editor, call, monkeypatch):
    from meshroom.mcp import editing
    node = editor.addNewNode("GroupAttributes")
    initial, index = snapshot(editor.graph), editor.undoStack.index
    monkeypatch.setattr(editing, "checkConnection", lambda graph, src, dst: None)  # Let Meshroom refuse it
    data, isError = call("meshroom_connect_nodes", source=f"{node.name}.exposedInt", destination="AppendText_1.input")
    assert isError and data["error"] == "INVALID_EDGE" and "(reverted)" in data["message"], data
    assert snapshot(editor.graph) == initial and editor.undoStack.index == index


@pyside
def test_loggedWarningIsAnErrorAndIsReverted(editor, call, monkeypatch):
    import logging
    from meshroom.ui import commands
    redo = commands.SetAttributeCommand.redoImpl

    def redoWithWarning(self):
        logging.warning("Something went wrong")
        return redo(self)
    monkeypatch.setattr(commands.SetAttributeCommand, "redoImpl", redoWithWarning)
    data, isError = call("meshroom_set_parameter", attribute="AppendText_1.inputText", value="x")
    assert isError and data["error"] == "MUTATION_FAILED" and "Something went wrong" in data["message"]
    assert editor.graph.attribute("AppendText_1.inputText").value == "Input text from AppendText_1"
    assert not editor.undoStack.canUndo


@pyside
def test_tryAndPushFalseIsAnError(editor, call, monkeypatch):
    from meshroom.ui import commands
    monkeypatch.setattr(commands.SetAttributeCommand, "redoImpl", lambda self: False)
    data, isError = call("meshroom_set_parameter", attribute="AppendText_1.inputText", value="x")
    assert isError and data["error"] == "MUTATION_FAILED"
    assert not editor.undoStack.canUndo


@pyside
def test_saveRefusals(editor, call, projectRoot, tmp_path):
    data, _ = call("meshroom_save_project")
    assert data["error"] == "SAVE_AS_REQUIRED"
    (projectRoot / "existing.mg").write_text("{}")
    (projectRoot / "link.mg").symlink_to(projectRoot / "existing.mg")
    for arguments, code in [
        ({"path": "relative.mg"}, "INVALID_PATH"),
        ({"path": str(projectRoot / "file.txt")}, "INVALID_PATH"),
        ({"path": str(tmp_path / "outside.mg")}, "PATH_OUTSIDE_ROOTS"),
        ({"path": str(projectRoot / ".." / "escape.mg")}, "PATH_OUTSIDE_ROOTS"),
        ({"path": str(projectRoot / "missing" / "x.mg")}, "INVALID_PATH"),
        ({"path": str(projectRoot / "existing.mg")}, "FILE_EXISTS"),
        ({"path": str(projectRoot / "link.mg"), "overwrite": True}, "INVALID_PATH"),
    ]:
        data, isError = call("meshroom_save_project", **arguments)
        assert isError and data["error"] == code, (arguments, data)
    assert (projectRoot / "existing.mg").read_text() == "{}"


@pyside
def test_saveOverwrite(editor, call, projectRoot):
    (projectRoot / "existing.mg").write_text("{}")
    data, isError = call("meshroom_save_project", path=str(projectRoot / "existing.mg"), overwrite=True)
    assert not isError and "graph" in json.loads((projectRoot / "existing.mg").read_text())
    editor.graph.attribute("AppendText_1.inputText").value = "In place"
    data, isError = call("meshroom_save_project", overwrite=True)
    assert not isError and data["path"] == str(projectRoot / "existing.mg") and not data["dirty"]
    assert "In place" in (projectRoot / "existing.mg").read_text()


@pyside
def test_saveRefusesToDropUnknownTopLevelKeys(editor, call, projectRoot):
    from meshroom.core.graph import loadGraph
    source = projectRoot / "withMetadata.mg"
    data = json.load(open(FIXTURE))
    data["header"].pop("template")
    data["studioMetadata"] = {"shot": "sh010"}
    source.write_text(json.dumps(data))
    editor.setGraph(loadGraph(str(source)))
    sourceHash = fileHash(source)
    for arguments in [{"path": str(projectRoot / "copy.mg")}, {"overwrite": True}]:
        result, isError = call("meshroom_save_project", **arguments)
        assert isError and result["error"] == "METADATA_LOSS" and "studioMetadata" in result["message"]
    assert not (projectRoot / "copy.mg").exists() and fileHash(source) == sourceHash


@pyside
def test_noProject(projectRoot):
    from meshroom.mcp.editing import createEditingTools
    from meshroom.mcp.tools import Session
    tool = next(t for t in createEditingTools(Session(lambda: None, lambda: [])) if t.name == "meshroom_add_node")
    result = tool.handler({"node_type": "AppendText"})
    assert result["isError"] and json.loads(result["content"][0]["text"])["error"] == "NO_PROJECT"
    shutil.rmtree(projectRoot)


@pyside
def test_saveAsGoesThroughTheApplication(editor, projectRoot):
    from meshroom.mcp.editing import createEditingTools
    from meshroom.mcp.tools import Session
    saved = []

    def saveAs(path):  # MeshroomApp.saveProjectAs also adds the file to the recent projects
        saved.append(path)
        editor.saveAs(path)
    session = Session(lambda: editor.graph, lambda: [str(projectRoot)], getEditor=lambda: editor, saveAs=saveAs)
    tool = next(t for t in createEditingTools(session) if t.name == "meshroom_save_project")
    result = tool.handler({"path": str(projectRoot / "viaApp.mg")})
    assert not result["isError"] and saved == [str(projectRoot / "viaApp.mg")]


@pytest.fixture
def cameraInit(editor):
    from tests.utils import registeredNodeTypes
    with registeredNodeTypes([CameraInit]):
        yield editor.addNewNode("CameraInit")


@pyside
@pytest.mark.parametrize("attribute, value", [
    ("viewpoints", [{"path": "/x.jpg"}]), ("viewpoints[0].path", "/x.jpg"), ("intrinsics", []),
])
def test_cameraInitViewsNeedTheImportTool(editor, call, cameraInit, attribute, value):
    if attribute.startswith("viewpoints["):
        cameraInit.viewpoints.value = [{"path": "/previous.jpg"}]
    index = editor.undoStack.index
    data, isError = call("meshroom_set_parameter", attribute=f"{cameraInit.name}.{attribute}", value=value)
    assert isError and data["error"] == "USE_IMPORT_TOOL", data
    assert editor.undoStack.index == index


@pyside
def test_importImages(editor, call, cameraInit, inputRoot, tmp_path, monkeypatch):
    received = []
    monkeypatch.setattr(editor, "handleFilesUrl", lambda filesByType, node: received.append((filesByType, node)),
                        raising=False)
    shots = inputRoot / "shots"
    shots.mkdir()
    (shots / "a.jpg").write_bytes(b"jpg")
    (shots / "notes.txt").write_text("x")
    (tmp_path / "outside.jpg").write_bytes(b"jpg")
    (shots / "link.jpg").symlink_to(tmp_path / "outside.jpg")

    data, isError = call("meshroom_import_images", node=cameraInit.name, paths=[str(shots)], dry_run=True)
    assert not isError and data["dryRun"] and data["images"] == [str(shots / "a.jpg")] and received == []
    assert sorted(data["ignored"]) == sorted([str(shots / "link.jpg"), str(shots / "notes.txt")])

    data, isError = call("meshroom_import_images", node=cameraInit.name, paths=[str(shots)])
    assert not isError and data["pending"]
    filesByType, node = received[0]
    assert node is cameraInit and filesByType["images"] == [str(shots / "a.jpg")]
    assert not any(filesByType[k] for k in ("videos", "panoramaInfo", "meshroomScenes", "meshroomTemplates", "other"))

    for arguments, code in [
        ({"node": "AppendText_1", "paths": [str(shots)]}, "INVALID_NODE"),
        ({"node": cameraInit.name, "paths": [str(tmp_path / "outside.jpg")]}, "PATH_OUTSIDE_ROOTS"),
        ({"node": cameraInit.name, "paths": ["shots/a.jpg"]}, "PATH_OUTSIDE_ROOTS"),
        ({"node": cameraInit.name, "paths": [str(inputRoot / "missing.jpg")]}, "INVALID_PATH"),
        ({"node": cameraInit.name, "paths": [str(shots / "notes.txt")]}, "NO_IMAGES"),
        ({"node": cameraInit.name, "paths": []}, "INVALID_ARGUMENT"),
    ]:
        data, isError = call("meshroom_import_images", **arguments)
        assert isError and data["error"] == code, (arguments, data)
    assert len(received) == 1


@pyside
def test_importImagesNeedsInputRoots(editor, cameraInit, inputRoot):
    from meshroom.mcp.editing import createEditingTools
    from meshroom.mcp.tools import Session
    session = Session(lambda: editor.graph, lambda: [], getEditor=lambda: editor)
    tool = next(t for t in createEditingTools(session) if t.name == "meshroom_import_images")
    result = tool.handler({"node": cameraInit.name, "paths": [str(inputRoot)]})
    assert result["isError"] and json.loads(result["content"][0]["text"])["error"] == "NO_INPUT_ROOTS"


def outdatedNodeDesc(old: bool):
    """ Node type 'Outdated': the version a project was saved with (old=True), or the current one. """
    class Outdated(desc.Node):
        inputs = [
            desc.File(name="input", value=""),
            desc.StringParam(name="count", value="three") if old else desc.IntParam(name="count", value=1),
            desc.StringParam(name="text", value="default"),
        ] + ([desc.File(name="oldInput", value=""), desc.IntParam(name="oldParam", value=0)] if old else [])
        outputs = [desc.File(name="output", value="{nodeCacheFolder}/out.txt")] \
            + ([desc.File(name="oldOutput", value="{nodeCacheFolder}/old.txt")] if old else [])
    return Outdated


@pytest.fixture
def outdated(editor, tmp_path):
    """ The editor on a project whose nodes Outdated_1 and Outdated_2 were saved with the old 'Outdated' type. """
    from meshroom.core.graph import Graph, loadGraph
    from tests.utils import registeredNodeTypes
    path = str(tmp_path / "outdated.mg")
    with registeredNodeTypes([outdatedNodeDesc(old=True)]):
        graph = Graph()
        text1, text2 = graph.addNewNode("AppendText"), graph.addNewNode("AppendText")
        first, second = graph.addNewNode("Outdated"), graph.addNewNode("Outdated")
        files = graph.addNewNode("AppendFiles")
        graph.addEdge(text1.output, first.input)
        graph.addEdge(text2.output, first.oldInput)
        graph.addEdge(first.output, files.input)
        graph.addEdge(first.oldOutput, files.input2)
        graph.addEdge(first.input, files.input3)  # From an input attribute: kept
        second.text.value, second.oldParam.value = "kept", 3
        graph.save(path)
    with registeredNodeTypes([outdatedNodeDesc(old=False)]):
        editor.setGraph(loadGraph(path))
        assert sorted(n.name for n in editor.graph.nodes if n.isCompatibilityNode) == ["Outdated_1", "Outdated_2"]
        yield editor


def edgeNames(graph):
    return sorted((e.src.fullName, e.dst.fullName) for e in graph.edges)


LOST_EDGES = [("AppendText_2.output", "Outdated_1.oldInput"), ("Outdated_1.oldOutput", "AppendFiles_1.input2")]


@pyside
def test_upgradeNodesDryRunChangesNothing(outdated, call):
    before, index = snapshot(outdated.graph), outdated.undoStack.index
    data, isError = call("meshroom_upgrade_nodes", dry_run=True, allowEdgeLoss=True)
    assert not isError and data["dryRun"] and [n["name"] for n in data["nodes"]] == ["Outdated_1", "Outdated_2"]
    assert data["nodes"][0]["issue"] and data["nodes"][0]["uid"]
    assert sorted((e["from"], e["to"]) for e in data["lostEdges"]) == LOST_EDGES
    assert snapshot(outdated.graph) == before and outdated.undoStack.index == index


@pyside
def test_upgradeNodesDryRunPredictsEdgeLoss(outdated, call):
    before = snapshot(outdated.graph)
    data, isError = call("meshroom_upgrade_nodes", dry_run=True)
    assert isError and data["error"] == "EDGE_LOST" and "would drop 2 edges" in data["message"], data
    assert "Outdated_1.oldOutput" in data["message"] and "Outdated_1.oldInput" in data["message"]
    assert snapshot(outdated.graph) == before
    data, isError = call("meshroom_upgrade_nodes", nodes=["Outdated_2"], dry_run=True)
    assert not isError and data["lostEdges"] == [], data


def test_hasPort():
    from meshroom.mcp.editing import hasPort
    ports = [desc.File(name="input", value=""),
             desc.ListAttribute(name="list", elementDesc=desc.GroupAttribute(name="group", items=[
                 desc.File(name="file", value="")]))]
    assert hasPort(ports, "input") and hasPort(ports, "list[2].file")
    assert not hasPort(ports, "nope") and not hasPort(ports, "input[0]") and not hasPort(ports, "list[0].nope")


@pyside
def test_upgradeNodesRefusesToLoseEdges(outdated, call):
    graph = outdated.graph
    before, index = snapshot(graph), outdated.undoStack.index
    data, isError = call("meshroom_upgrade_nodes")
    assert isError and data["error"] == "EDGE_LOST" and "(reverted)" in data["message"], data
    assert "Outdated_1.oldOutput" in data["message"] and "Outdated_1.oldInput" in data["message"]
    # Outdated_2, upgraded in the same change, is reverted with Outdated_1
    assert snapshot(graph) == before and outdated.undoStack.index == index


@pyside
def test_upgradeNodeWithoutEdgeLoss(outdated, call):
    graph = outdated.graph
    data, isError = call("meshroom_upgrade_nodes", nodes=["Outdated_2"])
    assert not isError and data["lostEdges"] == [] and data["undo"] == "Upgrade Node Outdated_2", data
    node = data["nodes"][0]
    assert node["changed"] == {"count": {"before": "three", "after": 1}}
    assert node["removed"] == {"oldInput": "", "oldParam": 3} and node["added"] == {}
    assert node["uid"]["after"] == graph.node("Outdated_2")._uid
    assert not graph.node("Outdated_2").isCompatibilityNode and graph.node("Outdated_2").text.value == "kept"
    assert graph.node("Outdated_1").isCompatibilityNode


@pyside
def test_upgradeNodesAllowingEdgeLossThenUndo(outdated, call):
    graph = outdated.graph
    edgesBefore = edgeNames(graph)
    data, isError = call("meshroom_upgrade_nodes", allowEdgeLoss=True)
    assert not isError and data["undo"] == "Upgrade 2 Nodes", data
    assert sorted((e["from"], e["to"]) for e in data["lostEdges"]) == LOST_EDGES
    first = data["nodes"][0]
    assert first["name"] == "Outdated_1" and first["changed"] == {"count": {"before": "three", "after": 1}}
    assert first["removed"] == {"oldInput": "{AppendText_2.output}", "oldParam": 0} and first["added"] == {}
    assert ("AppendText_1.output", "Outdated_1.input") in edgeNames(graph)
    assert ("Outdated_1.output", "AppendFiles_1.input") in edgeNames(graph)
    assert not any(n.isCompatibilityNode for n in graph.nodes)
    outdated.undoStack.undo()
    assert graph.node("Outdated_1").isCompatibilityNode and graph.node("Outdated_2").isCompatibilityNode
    assert edgeNames(graph) == edgesBefore


@pyside
@pytest.mark.parametrize("arguments, code", [
    ({"nodes": ["AppendText_1"]}, "NOT_UPGRADABLE"),
    ({"nodes": ["Nope_1"]}, "NODE_NOT_FOUND"),
    ({"nodes": []}, "INVALID_ARGUMENT"),
    ({"nodes": "Outdated_1"}, "INVALID_ARGUMENT"),
])
def test_upgradeNodesRefusals(outdated, call, arguments, code):
    data, isError = call("meshroom_upgrade_nodes", **arguments)
    assert isError and data["error"] == code, data


@pyside
def test_upgradeNodesWithNothingToUpgrade(call):
    data, isError = call("meshroom_upgrade_nodes")
    assert isError and data["error"] == "NOTHING_TO_UPGRADE"
