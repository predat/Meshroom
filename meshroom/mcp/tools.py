"""
Read-only MCP tools on the project open in Meshroom.

No Qt and no transport: the application gives access to its state through a Session, so the same tools
can work on a Graph loaded from disk. Nodes are designated by their name (e.g. "FeatureMatching_1"); their
UID is a hash of their inputs, given for information only.
"""
import datetime
import glob
import json
import os
import platform
import re
import time
from typing import Callable, List, Optional

import meshroom
from meshroom.core import cacheFolderName, pluginManager
from meshroom.core.attribute import ChoiceParam, ListAttribute
from meshroom.core.graph import Graph
from meshroom.mcp import security
from meshroom.mcp.rpc import Tool

# Size limits of the results. Truncations are reported in the result itself.
MAX_RESULT_SIZE = 200_000  # characters of JSON per list in a result
MAX_VALUE_ITEMS = 50  # items shown per list in an attribute value
MAX_VALUE_LENGTH = 2000  # characters shown per string in an attribute value
LIST_PAGE_SIZE = 20  # default number of items shown per ListAttribute by meshroom_get_node
LIST_PROJECTS_TIME_BUDGET = 2.0  # seconds spent by meshroom_list_projects scanning folders
LIST_PROJECTS_MAX_DEPTH = 2  # default depth of subfolders scanned by meshroom_list_projects
PROJECT_EXTENSION = ".mg"
# Node descriptions name one output file per view, intrinsic... with placeholders such as <VIEW_ID>
OUTPUT_PLACEHOLDER = re.compile(r"<[A-Z_]+>")


class ToolError(Exception):
    """ An expected error, reported to the client with a stable code. """
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class Session:
    """ What the tools may read from the running application. """
    def __init__(self, getGraph: Callable[[], Optional[Graph]], getProjectRoots: Callable[[], List[str]],
                 getApplicationState: Callable[[], dict] = dict, getEditor: Callable[[], object] = lambda: None,
                 saveAs: Optional[Callable[[str], None]] = None, getInputRoots: Callable[[], List[str]] = list):
        self.getGraph = getGraph  # The open project's graph, None when no project is open
        self.getProjectRoots = getProjectRoots  # Folders meshroom_list_projects/save_project may use
        self.getApplicationState = getApplicationState  # Application-level state, added to meshroom_environment
        # The UIGraph of the open project, whose undoable methods the editing tools use; None if not editable
        self.getEditor = getEditor
        # Save the open project as a new file like File > Save As does (recent projects); default: editor.saveAs
        self.saveAs = saveAs
        self.getInputRoots = getInputRoots  # Folders meshroom_import_images may read images from

    def graph(self) -> Graph:
        graph = self.getGraph()
        if graph is None:
            raise ToolError("NO_PROJECT", "No project is open in Meshroom: open or create one first.")
        return graph

    def editor(self):
        self.graph()
        editor = self.getEditor()
        if editor is None:
            raise ToolError("READ_ONLY", "This session cannot modify the project.")
        return editor


# Results

def fitList(items: list, budget: int = MAX_RESULT_SIZE) -> list:
    """ The items whose JSON size fits in 'budget' characters, in order: an item too big is skipped, not the next ones. """
    kept, size = [], 0
    for item in items:
        itemSize = len(json.dumps(item, default=str)) + 2
        if size + itemSize > budget:
            continue
        size += itemSize
        kept.append(item)
    return kept


def addList(result: dict, key: str, items: list, budget: int = MAX_RESULT_SIZE):
    """
    Set result[key] to the items fitting in 'budget', and report a truncation in result["truncated"],
    with the names of the omitted items when they have one.
    """
    kept = fitList(items, budget)
    result[key] = kept
    if len(kept) < len(items):
        truncation = {"shown": len(kept), "total": len(items)}
        keptIds = {id(item) for item in kept}
        omitted = [item["name"] for item in items
                   if id(item) not in keptIds and isinstance(item, dict) and "name" in item]
        if omitted:
            truncation["omitted"] = fitList(omitted, 10_000)
        result.setdefault("truncated", {})[key] = truncation


def boundValue(value, path: str, truncatedPaths: list):
    """ Copy of an attribute value with long strings and lists cut, the cut paths being added to 'truncatedPaths'. """
    if isinstance(value, str):
        if len(value) <= MAX_VALUE_LENGTH:
            return value
        truncatedPaths.append(path)
        return value[:MAX_VALUE_LENGTH]
    if isinstance(value, (list, tuple)):
        if len(value) > MAX_VALUE_ITEMS:
            truncatedPaths.append(path)
        return [boundValue(v, f"{path}[{i}]", truncatedPaths) for i, v in enumerate(value[:MAX_VALUE_ITEMS])]
    if isinstance(value, dict):
        return {k: boundValue(v, f"{path}.{k}", truncatedPaths) for k, v in value.items()}
    return value


def checkArguments(arguments: dict, schema: dict):
    """ Minimal check of the arguments against the tool's JSON schema: known names, required ones, types. """
    types = {"string": str, "boolean": bool, "integer": int, "object": dict, "array": list}
    properties = schema.get("properties", {})
    for name in arguments:
        if name not in properties:
            raise ToolError("INVALID_ARGUMENT", f"Unknown argument {name!r}, expected: {sorted(properties)}")
    for name in schema.get("required", []):
        if name not in arguments:
            raise ToolError("INVALID_ARGUMENT", f"Missing argument {name!r}")
    for name, value in arguments.items():
        expected = types.get(properties[name].get("type"))
        if expected and (not isinstance(value, expected) or (expected is int and isinstance(value, bool))):
            raise ToolError("INVALID_ARGUMENT", f"Argument {name!r} must be of type {properties[name]['type']}")


def makeTool(name: str, description: str, schema: dict, function: Callable[[dict], dict]) -> Tool:
    """ Wrap 'function' (arguments -> JSON data) into an MCP tool returning JSON text, or a coded error. """
    def handler(arguments: dict) -> dict:
        try:
            checkArguments(arguments, schema)
            data = function(arguments)
        except ToolError as e:
            data = {"error": e.code, "message": e.message}
            return {"content": [{"type": "text", "text": json.dumps(data)}], "isError": True}
        return {"content": [{"type": "text", "text": json.dumps(data, indent=1, default=str)}], "isError": False}
    return Tool(name, description, schema, handler)


# Graph description

def nodeSummary(node) -> dict:
    summary = {
        "name": node.name,
        "nodeType": node.nodeType,
        "label": node.label,
        "status": node.globalStatus,
        "locked": node.locked,
        "uid": node._uid,
    }
    if node.isCompatibilityNode:
        summary["compatibilityIssue"] = node.issueDetails
    return summary


def attributeErrors(attribute) -> list:
    try:
        return list(attribute.errorMessages)
    except Exception as e:  # Validators are plugin code
        return [f"Validator failed: {type(e).__name__}: {e}"]


def listPage(attribute, value: list, page: dict, truncatedPaths: list) -> dict:
    """
    The items [offset, offset + limit) of a ListAttribute value, with the list's total. Items which are groups keep
    only their scalar fields unless page["full"], and lose their "metadata" field unless page["includeMetadata"].
    """
    items, omittedFields = [], set()
    for i, item in enumerate(value[page["offset"]:page["offset"] + page["limit"]], page["offset"]):
        if isinstance(item, dict):
            omitted = {k for k, v in item.items() if (k == "metadata" and not page["includeMetadata"])
                       or (not page["full"] and isinstance(v, (list, dict)))}
            omittedFields |= omitted
            item = {k: v for k, v in item.items() if k not in omitted}
        items.append(boundValue(item, f"{attribute.fullName}[{i}]", truncatedPaths))
    result = {"value": items, "total": len(value)}
    if omittedFields:
        result["omittedFields"] = sorted(omittedFields)
    return result


def attributeDescription(attribute, truncatedPaths: list, page: dict) -> dict:
    value = attribute.evalValue if attribute.isOutput else attribute.getSerializedValue()
    description = {
        "name": attribute.name,
        "label": attribute.label,
        "type": attribute.type,
        "value": None,
        "isDefault": attribute.isDefault,
        "enabled": attribute.enabled,
    }
    if isinstance(attribute, ListAttribute) and isinstance(value, list):
        description.update(listPage(attribute, value, page, truncatedPaths))
    else:
        description["value"] = boundValue(value, attribute.fullName, truncatedPaths)
    if attribute.isLink:
        description["linkedFrom"] = attribute.inputLink.fullName
    if isinstance(attribute, ChoiceParam):
        description["choices"] = boundValue(list(attribute.values), f"{attribute.fullName}:choices", truncatedPaths)
    valueRange = getattr(attribute.desc, "range", None)
    if valueRange:
        description["range"] = list(valueRange)
    errors = attributeErrors(attribute) if attribute.isInput else []
    if errors:
        description["errors"] = errors
    return description


# Tools

NO_ARGUMENTS = {"type": "object", "properties": {}, "additionalProperties": False}


def aliceVisionVersion() -> dict:
    """ AliceVision version from $ALICEVISION_VERSION, else from the version.hpp of $ALICEVISION_ROOT. """
    if os.environ.get("ALICEVISION_VERSION"):
        return {"version": os.environ["ALICEVISION_VERSION"], "source": "$ALICEVISION_VERSION"}
    header = os.path.join(os.environ.get("ALICEVISION_ROOT", ""), "include", "aliceVision", "version.hpp")
    try:
        with open(header) as f:
            content = f.read()
    except OSError:
        return {"version": "unknown", "source": None}
    numbers = dict(re.findall(r"#define ALICEVISION_VERSION_(MAJOR|MINOR|REVISION)\s+(\d+)", content))
    if len(numbers) != 3:
        return {"version": "unknown", "source": None}
    result = {"version": f"{numbers['MAJOR']}.{numbers['MINOR']}.{numbers['REVISION']}", "source": header}
    status = re.search(r'#define ALICEVISION_VERSION_STATUS\s+"([^"]*)"', content)
    if status and status.group(1):
        result["status"] = status.group(1)
    return result


def viewCount(node) -> int:
    """ Number of views of the CameraInit nodes 'node' depends on. """
    nodes = [node] + node.getInputNodes(recursive=True, dependenciesOnly=True)
    return sum(len(n.attribute("viewpoints")) for n in nodes
               if n.nodeType == "CameraInit" and n.hasAttribute("viewpoints"))


def outputFiles(attribute) -> dict:
    """
    For a File output: its glob 'pattern' (placeholders such as <VIEW_ID> as '*'), the number of files 'matches' it
    and, when known, the number 'expected' (1 without placeholder, one per view for <VIEW_ID>). {} otherwise.
    """
    path = attribute.evalValue
    if attribute.type != "File" or not isinstance(path, str) or not path:
        return {}
    placeholders = set(OUTPUT_PLACEHOLDER.findall(path))
    pattern = OUTPUT_PLACEHOLDER.sub("*", path)
    isGlob = any(c in pattern for c in "*?[")
    matches = len(glob.glob(pattern)) if isGlob else int(os.path.exists(pattern))
    expected = None
    if not isGlob:
        expected = 1
    elif placeholders == {"<VIEW_ID>"} and not any(c in path for c in "*?["):
        expected = viewCount(attribute.node)
    return {"pattern": pattern, "matches": matches, "expected": expected}


def environment(session: Session, arguments: dict) -> dict:
    graph = session.getGraph()
    data = {
        "meshroom": meshroom.__version_label__,
        "aliceVision": aliceVisionVersion(),
        "python": platform.python_version(),
        "plugins": sorted(({"name": p.name, "version": p.version, "type": p.type.name}
                           for p in pluginManager.getPlugins().values()), key=lambda p: p["name"]),
        "project": None if graph is None else {
            "path": graph.filepath or None,
            "nodes": len(graph.nodes),
            "cacheDir": graph.cacheDir or None,
        },
    }
    data.update(session.getApplicationState())
    return data


def inspectProject(session: Session, arguments: dict) -> dict:
    graph = session.graph()
    data = {
        "path": graph.filepath or None,
        "cacheDir": graph.cacheDir or None,
        "fileReleaseVersion": graph.fileReleaseVersion,
    }
    addList(data, "nodes", [nodeSummary(n) for n in graph.nodes], MAX_RESULT_SIZE // 2)
    addList(data, "edges", [{"from": e.src.fullName, "to": e.dst.fullName} for e in graph.edges],
            MAX_RESULT_SIZE // 2)
    return data


def getNode(session: Session, arguments: dict) -> dict:
    node = session.graph().node(arguments["node"])
    if node is None:
        raise ToolError("NODE_NOT_FOUND", f"No node named {arguments['node']!r}. "
                        "Node names are listed by meshroom_inspect_project.")
    data = nodeSummary(node)
    data.update({
        "position": [node.x, node.y],
        "internalFolder": node.internalFolder,
    })
    if node.isCompatibilityNode:
        data["canUpgrade"] = node.canUpgrade
    names = arguments.get("attributes")
    if names is not None:
        if not names or not all(isinstance(n, str) for n in names):
            raise ToolError("INVALID_ARGUMENT", "'attributes' must be a non-empty list of attribute names")
        unknown = sorted(set(names) - {a.name for a in node.attributes})
        if unknown:
            raise ToolError("ATTRIBUTE_NOT_FOUND", f"No attribute {unknown} on {node.name}. "
                            "Call meshroom_get_node without 'attributes' to list them.")
    page = {"offset": arguments.get("offset", 0), "limit": arguments.get("limit", LIST_PAGE_SIZE),
            "full": names is not None, "includeMetadata": arguments.get("includeMetadata", False)}
    if page["offset"] < 0 or not 1 <= page["limit"] <= MAX_VALUE_ITEMS:
        raise ToolError("INVALID_ARGUMENT", f"'offset' must be >= 0 and 'limit' between 1 and {MAX_VALUE_ITEMS}")
    truncatedValues, inputs, outputs = [], [], []
    for attribute in node.attributes:
        if names is None or attribute.name in names:
            description = attributeDescription(attribute, truncatedValues, page)
            (outputs if attribute.isOutput else inputs).append(description)
    addList(data, "inputs", inputs, MAX_RESULT_SIZE // 2)
    addList(data, "outputs", outputs, MAX_RESULT_SIZE // 2)
    if truncatedValues:
        data.setdefault("truncated", {})["values"] = fitList(truncatedValues, 10_000)
    return data


def nodeIssues(graph: Graph, node) -> list:
    issues = []
    if node.isCompatibilityNode:
        issues.append({"node": node.name, "kind": "compatibility", "message": node.issueDetails,
                       "canUpgrade": node.canUpgrade})
    else:
        try:
            blocked = not graph.canComputeTopologically(node)
        except KeyError:  # Topological data not computed yet
            blocked = False
        if blocked:
            issues.append({"node": node.name, "kind": "blockedByCompatibility",
                           "message": "Depends on a node with a compatibility issue"})
    if node.hasDuplicates:
        issues.append({"node": node.name, "kind": "duplicate",
                       "message": "Same inputs as other nodes: they would compute the same data",
                       "duplicates": [d.name for d in node.duplicates]})
    for attribute in node.attributes:
        errors = attributeErrors(attribute) if attribute.isInput and attribute.enabled else []
        if errors:
            issues.append({"node": node.name, "attribute": attribute.fullName, "kind": "invalidValue",
                           "messages": errors})
    return issues


def validateGraph(session: Session, arguments: dict) -> dict:
    graph = session.graph()
    issues = [issue for node in graph.nodes for issue in nodeIssues(graph, node)]
    data = {"valid": not issues}
    addList(data, "issues", issues)
    return data


def projectFile(entry: os.DirEntry) -> Optional[dict]:
    """ Description of a project file entry, None if it is not one (symbolic links are not followed). """
    try:
        if not entry.is_file(follow_symlinks=False) or not entry.name.endswith(PROJECT_EXTENSION):
            return None
        st = entry.stat(follow_symlinks=False)
    except OSError:
        return None  # Removed meanwhile
    return {
        "path": entry.path,
        "modified": datetime.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds"),
        "size": st.st_size,
    }


def readFolder(folder: str):
    """ Visible subfolders (cache folders excepted) and project files of a folder, without following links. """
    subfolders, projects = [], []
    try:
        with os.scandir(folder) as iterator:
            for entry in iterator:
                if entry.name.startswith("."):
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if entry.name != cacheFolderName:
                        subfolders.append(entry.path)
                    continue
                project = projectFile(entry)
                if project:
                    projects.append(project)
    except OSError:
        pass  # Unreadable folder, or entry removed meanwhile
    return subfolders, projects


def scanProjects(start: str, maxDepth: int, deadline: float):
    """
    Project files under 'start', down to 'maxDepth' levels of subfolders, without following symbolic links.
    Return them, and whether the scan stopped at 'deadline' (time.monotonic()).
    """
    allProjects, folders = [], [(start, 0)]
    while folders:
        if time.monotonic() > deadline:
            return allProjects, True
        folder, depth = folders.pop()
        subfolders, projects = readFolder(folder)
        allProjects += projects
        if depth < maxDepth:
            folders += [(f, depth + 1) for f in subfolders]
    return allProjects, False


def scanStart(root: str, subdirectory: str) -> str:
    """ Canonical folder to scan for a configured root. Raise ValueError if it is invalid. """
    start = security.resolveUnderRoot(security.resolveRoot(root), subdirectory)
    if not os.path.isdir(start):
        raise ValueError(f"No folder {subdirectory!r} in this root")
    return start


def listProjects(session: Session, arguments: dict) -> dict:
    roots = session.getProjectRoots()
    if not roots:
        raise ToolError("NO_PROJECT_ROOTS", "No project roots are configured: set the 'MCP/projectRoots' "
                        "setting of Meshroom to the list of folders this tool may scan.")
    subdirectory = arguments.get("subdirectory", "")
    maxDepth = arguments.get("maxDepth", LIST_PROJECTS_MAX_DEPTH)
    if maxDepth < 0:
        raise ToolError("INVALID_ARGUMENT", "'maxDepth' must be positive or zero")
    # Runs on the main thread: the time budget bounds the UI freeze on slow file systems
    deadline = time.monotonic() + LIST_PROJECTS_TIME_BUDGET
    projects, invalidRoots, timedOut = [], [], False
    for root in roots:
        try:
            start = scanStart(root, subdirectory)
        except ValueError as e:
            invalidRoots.append({"root": root, "message": str(e)})
            continue
        found, timedOut = scanProjects(start, maxDepth, deadline)
        projects += found
        if timedOut:
            break
    if subdirectory and len(invalidRoots) == len(roots):
        raise ToolError("INVALID_PATH", f"{subdirectory!r} is not a folder inside any project root: "
                        f"{[r['message'] for r in invalidRoots]}")
    data = {"roots": roots, "maxDepth": maxDepth}
    if invalidRoots:
        data["invalidRoots"] = invalidRoots
    addList(data, "projects", sorted(projects, key=lambda p: p["path"]))
    if timedOut:
        data.setdefault("truncated", {})["time"] = (f"Scan stopped after {LIST_PROJECTS_TIME_BUDGET} s: "
                                                    "narrow it with 'subdirectory' or 'maxDepth'")
    return data


def createTools(session: Session) -> List[Tool]:
    def bind(function):
        return lambda arguments: function(session, arguments)

    return [
        makeTool("meshroom_environment",
                 "Versions of Meshroom, AliceVision (with where it was read), Python, Qt and the loaded plugins; "
                 "open project, unsaved changes and computation state. Read-only.",
                 NO_ARGUMENTS, bind(environment)),
        makeTool("meshroom_inspect_project",
                 "Summary of the project open in Meshroom: its nodes (name, type, label, status, lock, "
                 "compatibility issue, UID) and edges ('Node.attribute' to 'Node.attribute'). Lists are not "
                 "paginated: when one is cut, 'truncated' gives only its total. Read-only; use meshroom_get_node "
                 "for attribute values.",
                 NO_ARGUMENTS, bind(inspectProject)),
        makeTool("meshroom_get_node",
                 "One node of the open project: status, folders, and its input and output attributes with "
                 "values, links, choices, ranges and validation errors. A ListAttribute value is one page "
                 "('offset', 'limit') with the list's 'total'; its group items keep only their scalar fields "
                 "(the others in 'omittedFields') unless the attribute is named in 'attributes', and their "
                 "'metadata' field only with includeMetadata=true. Read-only.",
                 {"type": "object", "additionalProperties": False, "required": ["node"],
                  "properties": {
                      "node": {"type": "string", "description": "Node name, e.g. 'FeatureMatching_1'"},
                      "attributes": {"type": "array", "items": {"type": "string"},
                                     "description": "Names of the attributes to return, e.g. ['viewpoints']; "
                                                    "all by default. Their list items are returned whole"},
                      "offset": {"type": "integer", "minimum": 0,
                                 "description": "First item of each ListAttribute value; default 0"},
                      "limit": {"type": "integer", "minimum": 1, "maximum": MAX_VALUE_ITEMS,
                                "description": f"Items per ListAttribute value; default {LIST_PAGE_SIZE}"},
                      "includeMetadata": {"type": "boolean",
                                          "description": "Keep the 'metadata' field of list items (e.g. image "
                                                         "metadata of CameraInit viewpoints); default false"},
                  }},
                 bind(getNode)),
        makeTool("meshroom_validate_graph",
                 "Check the open project without modifying it: compatibility issues, nodes blocked by them, "
                 "duplicate nodes and invalid attribute values.",
                 NO_ARGUMENTS, bind(validateGraph)),
        makeTool("meshroom_list_projects",
                 "List the Meshroom project files (.mg) under the project roots configured in Meshroom "
                 "(setting 'MCP/projectRoots'), skipping hidden and cache folders and symbolic links. The scan "
                 f"is limited in depth and to {LIST_PROJECTS_TIME_BUDGET} s. Read-only.",
                 {"type": "object", "additionalProperties": False,
                  "properties": {
                      "subdirectory": {"type": "string",
                                       "description": "Only search this folder, relative to each root"},
                      "maxDepth": {"type": "integer", "minimum": 0,
                                   "description": f"Levels of subfolders scanned (default {LIST_PROJECTS_MAX_DEPTH})"},
                  }},
                 bind(listProjects)),
    ]
