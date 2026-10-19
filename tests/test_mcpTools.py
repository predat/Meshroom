import json
import os

import pytest

from meshroom.core import desc
from meshroom.core.graph import loadGraph
from meshroom.mcp import tools
from meshroom.mcp.tools import Session, createTools
from tests.utils import registeredNodeTypes

FIXTURE = os.path.join(os.path.dirname(__file__), "appendTextAndFiles.mg")


class NodeWithViews(desc.Node):
    """ A list of groups like CameraInit.viewpoints: scalar fields, a 'metadata' string and a nested group. """
    inputs = [
        desc.ListAttribute(name="views", elementDesc=desc.GroupAttribute(name="view", items=[
            desc.IntParam(name="viewId", value=-1),
            desc.StringParam(name="metadata", value=""),
            desc.GroupAttribute(name="center", items=[desc.FloatParam(name="x", value=0.0)]),
        ])),
        desc.StringParam(name="text", value="hello"),
    ]


def callTool(session, name, **arguments):
    tool = next(t for t in createTools(session) if t.name == name)
    result = tool.handler(arguments)
    return json.loads(result["content"][0]["text"]), result["isError"]


@pytest.fixture
def graph():
    return loadGraph(FIXTURE)


@pytest.fixture
def session(graph):
    return Session(lambda: graph, lambda: [], lambda: {"unsavedChanges": False})


def test_toolsDeclareObjectSchemas(session):
    names = [t.name for t in createTools(session)]
    assert names == ["meshroom_environment", "meshroom_inspect_project", "meshroom_get_node",
                     "meshroom_validate_graph", "meshroom_list_projects"]
    for tool in createTools(session):
        assert tool.inputSchema["type"] == "object"
        assert tool.inputSchema["additionalProperties"] is False


@pytest.mark.parametrize("name", ["meshroom_inspect_project", "meshroom_validate_graph"])
def test_noProjectOpen(name):
    data, isError = callTool(Session(lambda: None, lambda: []), name)
    assert isError
    assert data["error"] == "NO_PROJECT"


def test_environment(session):
    data, isError = callTool(session, "meshroom_environment")
    assert not isError
    assert data["project"]["nodes"] == 3
    assert "testNodes" in [p["name"] for p in data["plugins"]]
    assert data["unsavedChanges"] is False  # Application state is merged
    data, isError = callTool(Session(lambda: None, lambda: []), "meshroom_environment")
    assert not isError and data["project"] is None


def test_aliceVisionVersion(tmp_path, monkeypatch):
    monkeypatch.setenv("ALICEVISION_VERSION", "9.8.7")
    assert tools.aliceVisionVersion() == {"version": "9.8.7", "source": "$ALICEVISION_VERSION"}
    monkeypatch.delenv("ALICEVISION_VERSION")
    monkeypatch.setenv("ALICEVISION_ROOT", str(tmp_path))
    assert tools.aliceVisionVersion() == {"version": "unknown", "source": None}
    header = tmp_path / "include" / "aliceVision" / "version.hpp"
    header.parent.mkdir(parents=True)
    header.write_text("#define ALICEVISION_VERSION_MAJOR 3\n#define ALICEVISION_VERSION_MINOR 4\n"
                      "#define ALICEVISION_VERSION_REVISION 0\n#define ALICEVISION_VERSION_STATUS \"develop\"\n")
    assert tools.aliceVisionVersion() == {"version": "3.4.0", "source": str(header), "status": "develop"}
    header.write_text("#define ALICEVISION_VERSION_MAJOR 3\n")
    assert tools.aliceVisionVersion()["version"] == "unknown"


def test_inspectProject(session):
    data, isError = callTool(session, "meshroom_inspect_project")
    assert not isError
    assert sorted(n["name"] for n in data["nodes"]) == ["AppendFiles_1", "AppendText_1", "AppendText_2"]
    node = next(n for n in data["nodes"] if n["name"] == "AppendText_1")
    assert node["nodeType"] == "AppendText" and node["uid"] and node["status"] == "NONE"
    assert {"from": "AppendText_1.output", "to": "AppendFiles_1.input"} in data["edges"]
    assert len(data["edges"]) == 4
    assert "truncated" not in data


def test_inspectProjectTruncation(session, monkeypatch):
    monkeypatch.setattr(tools, "MAX_RESULT_SIZE", 400)
    data, _ = callTool(session, "meshroom_inspect_project")
    shown = [n["name"] for n in data["nodes"]]
    omitted = sorted({"AppendFiles_1", "AppendText_1", "AppendText_2"} - set(shown))
    assert len(shown) < 3
    truncation = data["truncated"]["nodes"]
    assert sorted(truncation.pop("omitted")) == omitted and truncation == {"shown": len(shown), "total": 3}


def test_getNode(session):
    data, isError = callTool(session, "meshroom_get_node", node="AppendFiles_1")
    assert not isError
    inputs = {a["name"]: a for a in data["inputs"]}
    assert inputs["input"]["linkedFrom"] == "AppendText_1.output"
    assert inputs["input"]["value"] == "{AppendText_1.output}"
    output = data["outputs"][0]
    assert output["name"] == "output" and "{" not in output["value"]  # Evaluated path
    assert output["value"].startswith(data["internalFolder"].rstrip("/"))


def test_getNodeLongValuesAreTruncated(session, graph):
    graph.node("AppendText_1").inputText.value = "x" * (tools.MAX_VALUE_LENGTH + 10)
    data, _ = callTool(session, "meshroom_get_node", node="AppendText_1")
    value = next(a["value"] for a in data["inputs"] if a["name"] == "inputText")
    assert len(value) == tools.MAX_VALUE_LENGTH
    assert data["truncated"]["values"] == ["AppendText_1.inputText"]


def test_getNodeTooBigValueDoesNotHideTheOthers(session, graph, monkeypatch):
    graph.node("AppendText_1").inputText.value = "x" * tools.MAX_VALUE_LENGTH
    monkeypatch.setattr(tools, "MAX_RESULT_SIZE", 3000)  # Inputs get half: less than inputText alone
    data, _ = callTool(session, "meshroom_get_node", node="AppendText_1")
    names = [a["name"] for a in data["inputs"]]
    assert "inputText" not in names and "input" in names
    assert data["truncated"]["inputs"] == {"shown": len(names), "total": len(names) + 1, "omitted": ["inputText"]}


@pytest.mark.parametrize("arguments, code", [
    ({"node": "Nope_1"}, "NODE_NOT_FOUND"),
    ({}, "INVALID_ARGUMENT"),
    ({"node": 3}, "INVALID_ARGUMENT"),
    ({"node": "AppendText_1", "extra": True}, "INVALID_ARGUMENT"),
    ({"node": "AppendText_1", "attributes": "input"}, "INVALID_ARGUMENT"),
    ({"node": "AppendText_1", "attributes": []}, "INVALID_ARGUMENT"),
    ({"node": "AppendText_1", "attributes": ["input", "nope"]}, "ATTRIBUTE_NOT_FOUND"),
    ({"node": "AppendText_1", "attributes": ["input[0]"]}, "ATTRIBUTE_NOT_FOUND"),
    ({"node": "AppendText_1", "offset": -1}, "INVALID_ARGUMENT"),
    ({"node": "AppendText_1", "limit": 0}, "INVALID_ARGUMENT"),
    ({"node": "AppendText_1", "limit": tools.MAX_VALUE_ITEMS + 1}, "INVALID_ARGUMENT"),
])
def test_getNodeErrors(session, arguments, code):
    data, isError = callTool(session, "meshroom_get_node", **arguments)
    assert isError and data["error"] == code


@pytest.fixture
def viewsNode(graph):
    with registeredNodeTypes([NodeWithViews]):
        node = graph.addNewNode("NodeWithViews")
        node.views.value = [{"viewId": i, "metadata": "{}", "center": {"x": 1.0}} for i in range(30)]
        yield node


def test_getNodeListPages(session, viewsNode):
    data, _ = callTool(session, "meshroom_get_node", node=viewsNode.name)
    views = next(a for a in data["inputs"] if a["name"] == "views")
    assert views["total"] == 30 and views["value"] == [{"viewId": i} for i in range(tools.LIST_PAGE_SIZE)]
    assert views["omittedFields"] == ["center", "metadata"]
    assert [a["name"] for a in data["inputs"]] == ["views", "text"] and "truncated" not in data
    data, _ = callTool(session, "meshroom_get_node", node=viewsNode.name, offset=25, limit=10)
    views = next(a for a in data["inputs"] if a["name"] == "views")
    assert views["total"] == 30 and [v["viewId"] for v in views["value"]] == list(range(25, 30))


def test_getNodeNamedAttributesAreWhole(session, viewsNode):
    data, _ = callTool(session, "meshroom_get_node", node=viewsNode.name, attributes=["views"], limit=2)
    assert [a["name"] for a in data["inputs"]] == ["views"] and data["outputs"] == []
    views = data["inputs"][0]
    assert views["value"] == [{"viewId": i, "center": {"x": 1.0}} for i in range(2)]
    assert views["omittedFields"] == ["metadata"]
    data, _ = callTool(session, "meshroom_get_node", node=viewsNode.name, attributes=["views"], limit=1,
                       includeMetadata=True)
    assert data["inputs"][0]["value"] == [{"viewId": 0, "metadata": "{}", "center": {"x": 1.0}}]
    assert "omittedFields" not in data["inputs"][0]


def test_validateGraph(session, graph):
    data, isError = callTool(session, "meshroom_validate_graph")
    assert not isError and data == {"valid": True, "issues": []}

    node = graph.addNewNode("NodeWithValidators")
    node.intRange.value = 9
    data, _ = callTool(session, "meshroom_validate_graph")
    assert not data["valid"]
    invalid = {i["attribute"] for i in data["issues"] if i["kind"] == "invalidValue"}
    assert invalid == {f"{node.name}.mandatory", f"{node.name}.intRange"}


def test_toolsDoNotModifyTheGraph(session, graph):
    before = json.dumps(graph.toDict(), default=str, sort_keys=True)
    for name, arguments in [("meshroom_environment", {}), ("meshroom_inspect_project", {}),
                            ("meshroom_get_node", {"node": "AppendFiles_1"}), ("meshroom_validate_graph", {})]:
        callTool(session, name, **arguments)
    assert json.dumps(graph.toDict(), default=str, sort_keys=True) == before


@pytest.fixture
def projectTree(tmp_path):
    root = tmp_path / "root"
    outside = tmp_path / "outside"
    for path in ["a.mg", "sub/b.mg", "sub/notes.txt", ".hidden/c.mg", "MeshroomCache/d.mg",
                 "d1/d2/e.mg", "d1/d2/d3/f.mg"]:
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_text("{}")
    outside.mkdir()
    (outside / "x.mg").write_text("{}")
    (root / "escape.mg").symlink_to(outside / "x.mg")
    (root / "escapeDir").symlink_to(outside, target_is_directory=True)
    (root / "inside.mg").symlink_to(root / "a.mg")  # Symbolic links are never followed, even inside the root
    return root


def listProjects(roots, **arguments):
    return callTool(Session(lambda: None, lambda: roots), "meshroom_list_projects", **arguments)


def test_listProjects(projectTree):
    data, isError = listProjects([str(projectTree)])
    assert not isError
    assert [p["path"] for p in data["projects"]] == [str(projectTree / p) for p in ["a.mg", "d1/d2/e.mg", "sub/b.mg"]]
    assert listProjects([str(projectTree)], subdirectory="sub")[0]["projects"][0]["path"] == str(projectTree / "sub/b.mg")


def test_listProjectsRefusesWithoutRoots():
    data, isError = listProjects([])
    assert isError and data["error"] == "NO_PROJECT_ROOTS"


@pytest.mark.parametrize("subdirectory", ["..", "/etc", "escapeDir", "missing"])
def test_listProjectsStaysInsideTheRoots(projectTree, subdirectory):
    data, isError = listProjects([str(projectTree)], subdirectory=subdirectory)
    assert isError and data["error"] == "INVALID_PATH"


def test_listProjectsReportsInvalidRoots(projectTree):
    data, isError = listProjects(["relative/root", str(projectTree / "missing"), str(projectTree)])
    assert not isError
    assert len(data["invalidRoots"]) == 2
    assert len(data["projects"]) == 3


@pytest.mark.parametrize("maxDepth, expected", [
    (0, ["a.mg"]),
    (2, ["a.mg", "d1/d2/e.mg", "sub/b.mg"]),
    (3, ["a.mg", "d1/d2/d3/f.mg", "d1/d2/e.mg", "sub/b.mg"]),
])
def test_listProjectsDepth(projectTree, maxDepth, expected):
    data, _ = listProjects([str(projectTree)], maxDepth=maxDepth)
    assert [p["path"] for p in data["projects"]] == [str(projectTree / p) for p in expected]
    assert listProjects([str(projectTree)], maxDepth=-1)[0]["error"] == "INVALID_ARGUMENT"


def test_listProjectsTimeBudget(projectTree, monkeypatch):
    monkeypatch.setattr(tools, "LIST_PROJECTS_TIME_BUDGET", -1)
    data, isError = listProjects([str(projectTree)])
    assert not isError
    assert "time" in data["truncated"]
    assert data["projects"] == []
