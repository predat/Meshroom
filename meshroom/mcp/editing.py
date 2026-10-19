"""
MCP tools editing the project open in Meshroom.

Every change goes through the undoable methods of the application's UIGraph: it shows in the UI at once and
can be undone with Ctrl+Z. Nothing is written to disk until meshroom_save_project.
A change Meshroom refuses (False from UndoStack.tryAndPush, exception, or a warning logged meanwhile) is an
error, and what it pushed on the undo stack is undone.
"""
import difflib
import json
import os
import re
from typing import Callable, List, Optional

from meshroom.core import desc, nodeVersion, pluginManager
from meshroom.core.attribute import Attribute, ListAttribute
from meshroom.core.exception import InvalidEdgeError
from meshroom.core.node import Position
from meshroom import multiview
from meshroom.mcp import security
from meshroom.mcp.rpc import LogCapture, Tool
from meshroom.mcp.tools import PROJECT_EXTENSION, Session, ToolError, addList, boundValue, makeTool, nodeSummary
from meshroom.ui import commands

# Attributes filled from the images by the native import (they need the image metadata): setting them by hand is
# refused. Partial viewpoints (e.g. only a path) make the 2D viewer crash.
IMPORT_ONLY_ATTRIBUTES = {"CameraInit": ("viewpoints", "intrinsics")}


# Lookups

def findNode(graph, name: str):
    node = graph.node(name)
    if node is None:
        raise ToolError("NODE_NOT_FOUND", f"No node named {name!r}. Node names are listed by meshroom_inspect_project.")
    return node


def findAttribute(graph, fullName: str) -> Attribute:
    """ Attribute from its full name: 'Node.attribute', 'Node.group.child' or 'Node.list[0]'. """
    nodeName, _, path = fullName.partition(".")
    node = findNode(graph, nodeName)
    try:
        attribute = node.attribute(path) if path else None
    except (ValueError, KeyError, IndexError):
        attribute = None
    if attribute is None:
        raise ToolError("ATTRIBUTE_NOT_FOUND", f"No attribute {fullName!r}. Attribute names are listed by "
                        "meshroom_get_node; use 'Node.group.child' or 'Node.list[0]' for nested ones.")
    return attribute


def checkEditable(node):
    if node.locked:
        raise ToolError("NODE_LOCKED", f"{node.name} is locked (being computed or submitted).")
    if node.isCompatibilityNode:
        raise ToolError("READ_ONLY", f"{node.name} has a compatibility issue and cannot be edited: "
                        f"{node.issueDetails}")


def isLinked(attribute) -> bool:
    """ Whether the attribute, or a list/group containing it, receives a connection. """
    while attribute is not None:
        if attribute.isLink:
            return True
        attribute = attribute.root
    return False


# Values

def checkValue(attributeDesc, value, path: str) -> List[str]:
    """
    Check a JSON value against an attribute descriptor, more strictly than Meshroom's own validation
    (which converts strings and truncates floats). Return warnings; raise ToolError on invalid values.
    """
    def invalid(message):
        raise ToolError("INVALID_VALUE", f"{path}: {message}")

    if isinstance(attributeDesc, desc.ListAttribute):
        if not isinstance(value, list):
            invalid("expected a list")
        return [w for i, v in enumerate(value) for w in checkValue(attributeDesc.elementDesc, v, f"{path}[{i}]")]
    if isinstance(attributeDesc, desc.GroupAttribute):
        children = {child.name: child for child in attributeDesc.items}
        if not isinstance(value, dict):
            invalid(f"expected an object with keys among {sorted(children)}")
        unknown = set(value) - set(children)
        if unknown:
            invalid(f"unknown keys {sorted(unknown)}, expected keys among {sorted(children)}")
        return [w for k, v in value.items() for w in checkValue(children[k], v, f"{path}.{k}")]
    return checkScalar(attributeDesc, value, path)


def checkScalar(attributeDesc, value, path: str) -> List[str]:
    """ checkValue for the attributes which are neither lists nor groups. """
    def invalid(message):
        raise ToolError("INVALID_VALUE", f"{path}: {message}")

    if isinstance(attributeDesc, (desc.PushButtonParam, desc.Flow)):
        invalid("this attribute has no value to set")
    if isinstance(attributeDesc, desc.ChoiceParam):
        return checkChoice(attributeDesc, value, path)
    if isinstance(attributeDesc, desc.BoolParam):
        if not isinstance(value, bool):
            invalid("expected a boolean")
        return []
    if isinstance(attributeDesc, (desc.IntParam, desc.FloatParam)):
        return checkNumber(attributeDesc, value, path)
    if isinstance(attributeDesc, (desc.StringParam, desc.File, desc.ColorParam)):
        if not isinstance(value, str):
            invalid("expected a string")
        if Attribute.isLinkExpression(value):
            invalid("link expressions are not values: use meshroom_connect_nodes")
    return []


def checkNumber(attributeDesc, value, path: str) -> List[str]:
    """ An out-of-range number is only a warning, as in the Node Editor. """
    expected = (int,) if isinstance(attributeDesc, desc.IntParam) else (int, float)
    if isinstance(value, bool) or not isinstance(value, expected):
        raise ToolError("INVALID_VALUE", f"{path}: expected " + ("an integer" if expected == (int,) else "a number"))
    valueRange = attributeDesc.range
    if valueRange and not valueRange[0] <= value <= valueRange[1]:
        return [f"{path}: {value} is outside of the usual range [{valueRange[0]}, {valueRange[1]}]"]
    return []


def checkChoice(attributeDesc, value, path: str) -> List[str]:
    values = list(attributeDesc.values)
    items = value if not attributeDesc.exclusive else [value]
    if not attributeDesc.exclusive and not isinstance(value, list):
        raise ToolError("INVALID_VALUE", f"{path}: expected a list of choices among {values}")
    for item in items:
        if isinstance(item, (dict, list)) or (values and item not in values):
            raise ToolError("INVALID_VALUE", f"{path}: {item!r} is not one of the choices {values}")
    return []


# Mutations

def runMutation(editor, action: Callable[[], object], succeeded: Callable[[object], bool] = lambda r: True,
                tolerated: Callable[[str], bool] = lambda line: False):
    """
    Run 'action', which pushes commands on the editor's undo stack. Fail if it raises, returns False, logs a
    warning (except the 'tolerated' ones) or does not satisfy 'succeeded'; what it pushed is then undone.
    """
    undoStack = editor.undoStack
    indexBefore = undoStack.index
    error, code = None, "MUTATION_FAILED"
    with LogCapture() as capture:
        try:
            result = action()
        except InvalidEdgeError as e:
            error, code, result = str(e), "INVALID_EDGE", None
        except Exception as e:
            error, result = f"{type(e).__name__}: {e}", None
    if error is None and result is False:
        error = "Meshroom refused the change"
    logged = [line for line in capture.lines if not tolerated(line)]
    if error is None and logged:
        error = "Meshroom logged: " + " | ".join(logged)
    if error is None and not succeeded(result):
        error = "The change did not happen"
    if error is not None:
        reverted = undoStack.index > indexBefore
        while undoStack.index > indexBefore:
            undoStack.undo()
        raise ToolError(code, error + (" (reverted)" if reverted else ""))
    return result


def editState(editor) -> dict:
    """ State of the project after a change: unsaved changes and what Ctrl+Z would undo. """
    return {"dirty": not editor.undoStack.isClean(), "undo": editor.undoStack.undoText or None}


def dryRunResult(editor, change: str, **details) -> dict:
    return {"dryRun": True, "change": "Would " + change, **details, **editState(editor)}


DRY_RUN = {"type": "boolean", "description": "Validate only, change nothing"}


def setParameter(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    attribute = findAttribute(graph, arguments["attribute"])
    checkEditable(attribute.node)
    rootName = attribute.fullName.split(".", 1)[1].split(".")[0].split("[")[0]
    if rootName in IMPORT_ONLY_ATTRIBUTES.get(attribute.node.nodeType, ()):
        raise ToolError("USE_IMPORT_TOOL", f"{attribute.fullName} is filled from the images' metadata: use "
                        "meshroom_import_images to add images.")
    if attribute.isOutput:
        raise ToolError("OUTPUT_ATTRIBUTE", f"{attribute.fullName} is an output: its value is computed.")
    if isLinked(attribute):
        raise ToolError("LINKED", f"{attribute.fullName} receives a connection: disconnect it first.")
    if attribute.desc.keyable:
        raise ToolError("KEYABLE_ATTRIBUTE", f"{attribute.fullName} is keyable (one value per key, e.g. per "
                        "frame): editing it is not supported, use the Node Editor.")
    value = arguments["value"]
    warnings = checkValue(attribute.desc, value, attribute.fullName)
    try:
        attribute.validateValue(value)
    except ValueError as e:
        raise ToolError("INVALID_VALUE", f"{attribute.fullName}: {e}")
    truncated = []
    previous = boundValue(attribute.getSerializedValue(), attribute.fullName, truncated)
    data = {"attribute": attribute.fullName, "previous": previous, "warnings": warnings}
    if attribute.getSerializedValue() == value:
        return {"change": "None: the attribute already has this value", **data, **editState(editor)}
    change = f"set {attribute.fullName}"
    if arguments.get("dry_run"):
        return dryRunResult(editor, change, **data)
    fullName = attribute.fullName
    runMutation(editor, lambda: editor.push(commands.SetAttributeCommand(graph, attribute, value)))
    data["value"] = boundValue(graph.attribute(fullName).getSerializedValue(), fullName, truncated)
    return {"change": change[0].upper() + change[1:], **data, **editState(editor)}


def addNode(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    nodeType = arguments["node_type"]
    nodeTypes = pluginManager.getNodeDescProviders()
    if nodeType not in nodeTypes:
        close = difflib.get_close_matches(nodeType, list(nodeTypes), n=5)
        raise ToolError("UNKNOWN_NODE_TYPE", f"Unknown node type {nodeType!r}" + (f", close: {close}" if close else ""))
    position = arguments.get("position")
    if position is not None:
        isNumber = [isinstance(v, (int, float)) and not isinstance(v, bool) for v in position.values()]
        if set(position) != {"x", "y"} or not all(isNumber):
            raise ToolError("INVALID_ARGUMENT", "'position' must be {\"x\": number, \"y\": number}")
        position = Position(position["x"], position["y"])
    if arguments.get("dry_run"):
        return dryRunResult(editor, f"add a {nodeType} node", nodeType=nodeType)
    node = runMutation(editor, lambda: editor.addNewNode(nodeType, position=position), lambda n: n is not None)
    return {"change": f"Added {node.name} ({nodeType})", "node": nodeSummary(node), **editState(editor)}


def importableImages(session: Session, paths) -> tuple:
    """ Images found in 'paths' (files or folders) which are inside an input root, and the ignored paths. """
    roots = security.validRoots(session.getInputRoots())
    if not roots:
        raise ToolError("NO_INPUT_ROOTS", "No valid input roots are configured: set the 'MCP/inputRoots' setting of "
                        "Meshroom to the folders images may be imported from.")
    if not isinstance(paths, list) or not paths or not all(isinstance(p, str) for p in paths):
        raise ToolError("INVALID_ARGUMENT", "'paths' must be a non-empty list of paths")
    filesByType = multiview.FilesByType()
    for path in paths:
        resolved = os.path.realpath(path)
        if not os.path.isabs(path) or not any(security.isUnder(resolved, r) for r in roots):
            raise ToolError("PATH_OUTSIDE_ROOTS", f"{path!r} is not inside an input root {roots}")
        if not os.path.exists(resolved):
            raise ToolError("INVALID_PATH", f"{path!r} does not exist")
        if os.path.isdir(resolved):
            filesByType.extend(multiview.findFilesByTypeInFolder(resolved))
        else:
            filesByType.addFile(resolved)
    # A folder may contain links leading out of the roots
    images = [i for i in filesByType.images if any(security.isUnder(os.path.realpath(i), r) for r in roots)]
    ignored = [p for p in filesByType.images if p not in images] + filesByType.videos + filesByType.panoramaInfo \
        + filesByType.meshroomScenes + filesByType.meshroomTemplates + filesByType.other
    return images, ignored


def importImages(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    node = findNode(editor.graph, arguments["node"])
    if node.nodeType != "CameraInit":
        raise ToolError("INVALID_NODE", f"{node.name} is a {node.nodeType}: images are imported into CameraInit nodes")
    checkEditable(node)
    images, ignored = importableImages(session, arguments["paths"])
    if not images:
        raise ToolError("NO_IMAGES", f"No image found in {arguments['paths']} (ignored: {ignored[:20]})")
    data = {"node": node.name}
    addList(data, "images", images, 50_000)
    addList(data, "ignored", ignored, 20_000)
    change = f"import {len(images)} images into {node.name}"
    if arguments.get("dry_run"):
        return dryRunResult(editor, change, **data)
    # Same path as dropping the images on the node: metadata and intrinsics are read in a worker thread, then the
    # views are added by one undoable command ("Add N Images")
    filesByType = {"images": images, "videos": [], "panoramaInfo": [], "meshroomScenes": [], "meshroomTemplates": [],
                   "other": []}
    with LogCapture() as capture:
        try:
            editor.handleFilesUrl(filesByType, node)
        except Exception as e:
            raise ToolError("IMPORT_FAILED", f"{type(e).__name__}: {e}")
    if capture.lines:
        raise ToolError("IMPORT_FAILED", " | ".join(capture.lines))
    return {"change": f"Importing {len(images)} images into {node.name}", "pending": True,
            "note": "The images' metadata is read in the background: the views appear in a moment, as one undoable "
                    "change. Check them with meshroom_get_node.", **data, **editState(editor)}


def edgeName(edge) -> dict:
    return {"from": edge.src.fullName, "to": edge.dst.fullName}


def removeNode(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    node = findNode(graph, arguments["node"])
    # UIGraph.removeNodes silently ignores locked nodes: refuse them explicitly
    checkEditable(node)
    name = node.name
    edges = [edgeName(e) for e in graph.edges if e.src.node is node or e.dst.node is node]
    change = f"remove {name} and its {len(edges)} edges (computed data on disk is kept)"
    if arguments.get("dry_run"):
        return dryRunResult(editor, change, removedEdges=edges)
    runMutation(editor, lambda: editor.removeNodes([node]), lambda r: graph.node(name) is None)
    return {"change": change[0].upper() + change[1:], "removedEdges": edges, **editState(editor)}


def isConnected(graph, src, dst) -> bool:
    """ Whether an edge goes from 'src' (or one of its elements) to 'dst' (or one of its elements). """
    return any((e.src is src or e.src.root is src) and (e.dst is dst or e.dst.root is dst) for e in graph.edges)


def checkConnection(graph, src, dst):
    if dst.isOutput:
        raise ToolError("INVALID_DIRECTION", f"{dst.fullName} is an output: connect to an input attribute.")
    if src.node is dst.node or src.node in graph.getOutputNodes(dst.node, recursive=True, dependenciesOnly=False):
        raise ToolError("CYCLE", f"Connecting {src.fullName} to {dst.fullName} would create a cycle.")
    if not dst.validateIncomingConnection(src):
        raise ToolError("INCOMPATIBLE_TYPES", f"{src.fullName} ({src.type}) cannot be connected to "
                        f"{dst.fullName} ({dst.type}).")


def connectNodes(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    src = findAttribute(graph, arguments["source"])
    dst = findAttribute(graph, arguments["destination"])
    checkEditable(dst.node)
    checkConnection(graph, src, dst)
    existing = graph.edge(dst)
    replaced = edgeName(existing) if existing is not None else None
    change = f"connect {src.fullName} to {dst.fullName}"
    if arguments.get("dry_run"):
        return dryRunResult(editor, change, replacedEdge=replaced)
    runMutation(editor, lambda: editor.addEdge(src, dst), lambda r: isConnected(graph, src, dst))
    return {"change": change[0].upper() + change[1:], "replacedEdge": replaced, **editState(editor)}


def disconnectNodes(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    dst = findAttribute(graph, arguments["destination"])
    edge = graph.edge(dst)
    if edge is None:
        raise ToolError("NOT_CONNECTED", f"{dst.fullName} receives no connection.")
    checkEditable(dst.node)
    removed = edgeName(edge)
    # An element of a list is removed with its connection, as in the Graph Editor
    listElement = isinstance(dst.root, ListAttribute)
    change = f"disconnect {removed['from']} from {removed['to']}" + (" and remove this list element" if listElement else "")
    if arguments.get("dry_run"):
        return dryRunResult(editor, change, removedEdge=removed)
    runMutation(editor, lambda: editor.removeEdge(edge),
                lambda r: all(edgeName(e) != removed for e in graph.edges))
    return {"change": change[0].upper() + change[1:], "removedEdge": removed, **editState(editor)}


# Upgrade

def inputValues(node) -> dict:
    return {a.name: a.getSerializedValue() for a in node.attributes if a.isInput}


def valueChanges(before: dict, after: dict, nodeName: str, truncated: list) -> dict:
    """ Input attributes changed, removed and added by an upgrade, with their values. """
    def bound(name, value):
        return boundValue(value, f"{nodeName}.{name}", truncated)
    return {
        "changed": {k: {"before": bound(k, before[k]), "after": bound(k, after[k])}
                    for k in sorted(before.keys() & after.keys()) if before[k] != after[k]},
        "removed": {k: bound(k, before[k]) for k in sorted(before.keys() - after.keys())},
        "added": {k: bound(k, after[k]) for k in sorted(after.keys() - before.keys())},
    }


def hasPort(attributeDescs, path: str) -> bool:
    """ Whether the attribute path 'path' ("group.list[0].child") exists in 'attributeDescs'. """
    children, attributeDesc = attributeDescs, None
    for token in re.findall(r"\[\d+\]|[^.\[\]]+", path):
        if token.startswith("["):
            if not isinstance(attributeDesc, desc.ListAttribute):
                return False
            attributeDesc = attributeDesc.elementDesc
        else:
            attributeDesc = next((d for d in children if d.name == token), None)
            if attributeDesc is None:
                return False
        children = attributeDesc.items if isinstance(attributeDesc, desc.GroupAttribute) else []
    return True


def predictedLostEdges(graph, node) -> list:
    """
    Edges of 'node' whose attribute is not in the current description of its type. A description's own
    'upgradeAttributeValues' may still rename some: the real upgrade checks again.
    """
    nodeDesc = node.nodeDesc
    # An outgoing edge may start from an input attribute
    edges = [(e, e.dst) for e in graph.nodeInEdges(node)] + [(e, e.src) for e in graph.nodeOutEdges(node)]
    return [edgeName(e) for e, attribute in edges
            if not hasPort(nodeDesc.outputs if attribute.isOutput else nodeDesc.inputs,
                           attribute.fullName.split(".", 1)[1])]


def upgradableNodes(graph, names) -> list:
    if names is None:
        nodes = sorted((n for n in graph.nodes if n.isCompatibilityNode and n.canUpgrade), key=lambda n: n.name)
        if not nodes:
            raise ToolError("NOTHING_TO_UPGRADE", "No node has a compatibility issue an upgrade can fix.")
        return nodes
    if not isinstance(names, list) or not names or not all(isinstance(n, str) for n in names):
        raise ToolError("INVALID_ARGUMENT", "'nodes' must be a non-empty list of node names")
    nodes = [findNode(graph, name) for name in dict.fromkeys(names)]
    for node in nodes:
        if not node.isCompatibilityNode:
            raise ToolError("NOT_UPGRADABLE", f"{node.name} has no compatibility issue.")
        if not node.canUpgrade:
            raise ToolError("NOT_UPGRADABLE", f"{node.name} cannot be upgraded: {node.issueDetails}")
    return nodes


def runUpgrade(editor, nodes: list, allowEdgeLoss: bool) -> list:
    """ Upgrade 'nodes' as one undoable change and return the edges lost. On failure, the graph is as before. """
    graph = editor.graph
    names = [n.name for n in nodes]

    def upgrade():
        if len(nodes) == 1:
            return editor.upgradeNode(nodes[0])
        with editor.groupedGraphModification(f"Upgrade {len(nodes)} Nodes"):
            return all([editor.upgradeNode(n) for n in nodes])  # A list: upgrade them all before checking

    edgesBefore = [edgeName(e) for e in graph.edges]
    indexBefore = editor.undoStack.index

    def missingEdges():
        edges = [edgeName(e) for e in graph.edges]
        return [e for e in edgesBefore if e not in edges]

    # Outgoing edges Meshroom cannot restore are logged: they are checked below with the incoming ones, which an
    # upgrade drops silently when their attribute no longer exists
    runMutation(editor, upgrade, lambda r: not any(graph.node(name).isCompatibilityNode for name in names),
                tolerated=lambda line: "Failed to restore edge" in line)
    lostEdges = missingEdges()
    if lostEdges and not allowEdgeLoss:
        while editor.undoStack.index > indexBefore:
            editor.undoStack.undo()
        reverted = "reverted" if not missingEdges() else f"reverted, but {missingEdges()[:50]} are still missing"
        raise ToolError("EDGE_LOST", f"The upgrade drops {len(lostEdges)} edges: {lostEdges[:50]} ({reverted}). "
                        "Call again with allowEdgeLoss=true to upgrade anyway and reconnect them by hand.")
    return lostEdges


def upgradeNodes(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    nodes = upgradableNodes(graph, arguments.get("nodes"))
    locked = [n.name for n in nodes if n.locked]
    if locked:
        raise ToolError("NODE_LOCKED", f"{locked} are locked (being computed or submitted).")
    before = {n.name: {"issue": n.issueDetails, "uid": n._uid, "version": n.nodeDict.get("version"),
                       "inputs": inputValues(n)} for n in nodes}
    change = f"upgrade {len(nodes)} nodes"
    allowEdgeLoss = arguments.get("allowEdgeLoss", False)
    if arguments.get("dry_run"):
        lostEdges = [e for n in nodes for e in predictedLostEdges(graph, n)]
        if lostEdges and not allowEdgeLoss:
            raise ToolError("EDGE_LOST", f"The upgrade would drop {len(lostEdges)} edges: {lostEdges[:50]}. "
                            "Call again with allowEdgeLoss=true to upgrade anyway and reconnect them by hand.")
        planned = [{"name": n.name, "issue": b["issue"], "uid": b["uid"],
                    "version": {"before": b["version"], "after": nodeVersion(n.nodeDesc)}}
                   for n, b in zip(nodes, before.values())]
        data = dryRunResult(editor, change)
        addList(data, "nodes", planned)
        addList(data, "lostEdges", lostEdges, 20_000)
        return data
    lostEdges = runUpgrade(editor, nodes, allowEdgeLoss)
    truncated, results = [], []
    for name, b in before.items():
        node = graph.node(name)
        results.append({"name": name, "issue": b["issue"], "uid": {"before": b["uid"], "after": node._uid},
                        "version": {"before": b["version"], "after": nodeVersion(node.nodeDesc)},
                        **valueChanges(b["inputs"], inputValues(node), name, truncated)})
    data = {"change": change[0].upper() + change[1:]}
    addList(data, "nodes", results)
    addList(data, "lostEdges", lostEdges, 20_000)
    if truncated:
        data.setdefault("truncated", {})["values"] = truncated[:200]
    return {**data, **editState(editor)}


# Saving

def topLevelKeys(path: str) -> Optional[set]:
    """ Top-level keys of a saved project, None if there is no readable file. """
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return set(data) if isinstance(data, dict) else None


def checkTopLevelKeysKept(graph) -> Optional[set]:
    """
    Meshroom only writes the keys it knows: refuse to write the graph if it would drop other top-level keys of
    the open project file. Return the keys of that file (None if there is none).
    """
    current = graph.filepath or None
    originalKeys = topLevelKeys(current) if current else None
    lost = sorted(originalKeys - set(graph.serialize())) if originalKeys else []
    if lost:
        raise ToolError("METADATA_LOSS", f"Writing the project would drop the top-level keys {lost} of {current}")
    return originalKeys


def saveTarget(session: Session, path: str, overwrite: bool) -> str:
    """ Canonical path where 'save as' may write, inside a project root. """
    if not os.path.isabs(path) or not path.endswith(PROJECT_EXTENSION):
        raise ToolError("INVALID_PATH", f"Expected an absolute path to a '{PROJECT_EXTENSION}' file, got {path!r}")
    roots = session.getProjectRoots()
    if not roots:
        raise ToolError("NO_PROJECT_ROOTS", "No project roots are configured: set the 'MCP/projectRoots' setting "
                        "of Meshroom to the folders where projects may be saved.")
    folder = os.path.realpath(os.path.dirname(path))
    target = os.path.join(folder, os.path.basename(path))
    validRoots = []
    for root in roots:
        try:
            validRoots.append(security.resolveRoot(root))
        except ValueError:
            continue
    if not any(security.isUnder(folder, r) for r in validRoots):
        raise ToolError("PATH_OUTSIDE_ROOTS", f"{path!r} is not inside a project root {roots}")
    if not os.path.isdir(folder):
        raise ToolError("INVALID_PATH", f"Folder {os.path.dirname(path)!r} does not exist")
    if os.path.islink(target):
        raise ToolError("INVALID_PATH", f"{path!r} is a symbolic link")
    if os.path.exists(target) and not overwrite:
        raise ToolError("FILE_EXISTS", f"{path!r} already exists: pass overwrite=true to replace it")
    return target


def saveProject(session: Session, arguments: dict) -> dict:
    editor = session.editor()
    graph = editor.graph
    path, overwrite = arguments.get("path"), arguments.get("overwrite", False)
    current = graph.filepath or None
    if path is None:
        if not overwrite:
            raise ToolError("SAVE_AS_REQUIRED", "Give a 'path' to save a new file, or overwrite=true to "
                            "overwrite the open project file.")
        if current is None:
            raise ToolError("NEVER_SAVED", "The project was never saved: give a 'path'.")
        target = current
    else:
        target = saveTarget(session, path, overwrite)
    originalKeys = checkTopLevelKeysKept(graph)
    inPlace = target == current
    change = (f"overwrite {target}" if inPlace else
              f"save as {target}, which becomes the open project (its cache is next to it)")
    if arguments.get("dry_run"):
        return dryRunResult(editor, change, path=target, previousPath=current)
    with LogCapture() as capture:
        try:
            editor.save() if inPlace else (session.saveAs or editor.saveAs)(target)
        except Exception as e:
            raise ToolError("SAVE_FAILED", f"{type(e).__name__}: {e}")
    savedKeys = topLevelKeys(target)
    if savedKeys is None:
        raise ToolError("SAVE_FAILED", f"{target} cannot be read back")
    lost = sorted((originalKeys or set()) - savedKeys)
    if lost or capture.lines:
        raise ToolError("SAVE_FAILED", f"{target} was written, but: " + " | ".join(
            ([f"top-level keys {lost} were dropped"] if lost else []) + capture.lines))
    return {"change": change[0].upper() + change[1:], "path": target, "previousPath": current, **editState(editor)}


# Declarations

def createEditingTools(session: Session) -> List[Tool]:
    def bind(function):
        return lambda arguments: function(session, arguments)

    def schema(required, **properties):
        return {"type": "object", "additionalProperties": False, "required": required,
                "properties": {**properties, "dry_run": DRY_RUN}}

    attributeName = {"type": "string", "description": "Full attribute name: 'Node.attribute', 'Node.group.child' "
                     "or 'Node.list[0]'"}
    undoable = " Undoable in Meshroom (Ctrl+Z); not saved to disk."
    return [
        makeTool("meshroom_set_parameter",
                 "Set the value of an input attribute: JSON value of the attribute's type (list for list attributes, "
                 "object for groups). Refused for outputs (OUTPUT_ATTRIBUTE), connected attributes (LINKED), "
                 "CameraInit viewpoints and intrinsics, filled by meshroom_import_images (USE_IMPORT_TOOL), "
                 "keyable attributes, which hold one value per key (KEYABLE_ATTRIBUTE), and locked nodes "
                 "(NODE_LOCKED)." + undoable,
                 schema(["attribute", "value"], attribute=attributeName,
                        value={"description": "New value, of the attribute's type"}),
                 bind(setParameter)),
        makeTool("meshroom_import_images",
                 "Import images (files or folders, inside the input roots of the 'MCP/inputRoots' setting) into a "
                 "CameraInit node, as dropping them on it in the Graph Editor: their metadata is read in the "
                 "background and the views are added in a moment, as one change." + undoable,
                 schema(["node", "paths"], node={"type": "string", "description": "CameraInit node name"},
                        paths={"type": "array", "items": {"type": "string"},
                               "description": "Absolute paths of images or folders of images"}),
                 bind(importImages)),
        makeTool("meshroom_add_node",
                 "Add a node of the given type and return its name." + undoable,
                 schema(["node_type"], node_type={"type": "string", "description": "Node type, e.g. 'FeatureMatching'"},
                        position={"type": "object", "description": "{\"x\": number, \"y\": number}"}),
                 bind(addNode)),
        makeTool("meshroom_remove_node",
                 "Remove a node and its edges. Computed data on disk is kept. Refused for locked nodes." + undoable,
                 schema(["node"], node={"type": "string", "description": "Node name, e.g. 'FeatureMatching_1'"}),
                 bind(removeNode)),
        makeTool("meshroom_connect_nodes",
                 "Connect an attribute to an input attribute, replacing the connection it already receives. "
                 "Refused for incompatible types, cycles and locked nodes." + undoable,
                 schema(["source", "destination"], source=attributeName, destination=attributeName),
                 bind(connectNodes)),
        makeTool("meshroom_disconnect_nodes",
                 "Remove the connection an input attribute receives (and the list element it is in, if any)." + undoable,
                 schema(["destination"], destination=attributeName),
                 bind(disconnectNodes)),
        makeTool("meshroom_upgrade_nodes",
                 "Upgrade nodes with a compatibility issue to the current version of their node type, as 'Upgrade' "
                 "in the Graph Editor (all the upgradable ones by default, as one change). Reports per node the UID "
                 "and version before and after, and the input attributes changed, removed and added; a new UID means "
                 "a new cache folder, to compute again. If edges cannot be restored (attribute removed or renamed), "
                 "nothing is changed (EDGE_LOST) unless allowEdgeLoss=true; the lost edges are then listed. The dry run "
                 "predicts the lost edges from the attributes of the current node type."
                 + undoable,
                 schema([], nodes={"type": "array", "items": {"type": "string"},
                                   "description": "Names of the nodes to upgrade; all the upgradable ones by default"},
                        allowEdgeLoss={"type": "boolean",
                                       "description": "Upgrade even if edges are lost; default false"}),
                 bind(upgradeNodes)),
        makeTool("meshroom_save_project",
                 "Save the open project. With 'path' (an absolute .mg path inside a project root of the "
                 "'MCP/projectRoots' setting), save as a new file which becomes the open project; existing files are "
                 "only replaced with overwrite=true. Without 'path', overwrite the open project file, only with "
                 "overwrite=true. Refused if it would drop unknown top-level keys of the project file.",
                 schema([], path={"type": "string", "description": "Absolute path of the new .mg file"},
                        overwrite={"type": "boolean", "description": "Allow replacing an existing file"}),
                 bind(saveProject)),
    ]
