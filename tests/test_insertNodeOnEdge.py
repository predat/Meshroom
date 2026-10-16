"""
Tests for the insertion of a node on an edge (UIGraph.insertNodeOnEdge) and the edges cutting.
"""
import pytest

from meshroom.core import desc
from meshroom.core.graph import Graph
from meshroom.ui import commands
from meshroom.ui.graph import UIGraph

from .utils import registeredNodeTypes


class FileNode(desc.Node):
    inputs = [
        desc.File(name="input", value=""),
        desc.ListAttribute(name="inputs", elementDesc=desc.File(name="path", value=""), exposed=True),
    ]
    outputs = [
        desc.File(name="output", value="{nodeCacheFolder}/out.sfm"),
    ]

    def process(self, node):
        pass


class TwoOutputsNode(desc.Node):
    inputs = [
        desc.File(name="input", value=""),
    ]
    outputs = [
        desc.File(name="poses", value="{nodeCacheFolder}/cameras.sfm"),
        # Undetermined value: generic data type
        desc.File(name="output", value=lambda attr: "{nodeCacheFolder}/out.sfm"),
    ]

    def process(self, node):
        pass


class IntNode(desc.Node):
    inputs = [
        desc.IntParam(name="value", value=0, range=None),
    ]
    outputs = [
        desc.IntParam(name="result", value=0, range=None),
    ]

    def process(self, node):
        pass


class GraphEditing:
    """
    The UIGraph editing methods on a core Graph: UIGraph itself needs the Qt backend,
    while the tests run with the standalone one.
    """
    push = UIGraph.push
    groupedGraphModification = UIGraph.groupedGraphModification
    addEdge = UIGraph.addEdge
    _addEdge = UIGraph._addEdge
    removeEdge = UIGraph.removeEdge
    appendAttribute = UIGraph.appendAttribute
    removeAttribute = UIGraph.removeAttribute
    deleteEdgesByIndices = UIGraph.deleteEdgesByIndices
    insertionAttributes = UIGraph.insertionAttributes
    insertNodeOnEdge = UIGraph.insertNodeOnEdge

    def __init__(self):
        self.graph = self._graph = Graph("")
        self.undoStack = self._undoStack = commands.UndoStack()

    def addNewNode(self, nodeType):
        return self._graph.addNewNode(nodeType)


@pytest.fixture
def uigraph():
    with registeredNodeTypes([FileNode, TwoOutputsNode, IntNode]):
        yield GraphEditing()


def edgeNames(graph):
    return sorted((e.src.fullName, e.dst.fullName) for e in graph.edges)


def test_insertCompatible(uigraph):
    graph = uigraph.graph
    nodeA, nodeB, node = (uigraph.addNewNode(FileNode.__name__) for _ in range(3))
    graph.addEdge(nodeA.output, nodeB.input)
    before = edgeNames(graph)
    undoIndex = uigraph.undoStack.index

    assert uigraph.insertNodeOnEdge(node, graph.edge(nodeB.input))
    assert edgeNames(graph) == sorted([(nodeA.output.fullName, node.input.fullName),
                                       (node.output.fullName, nodeB.input.fullName)])
    # A single undo step
    assert uigraph.undoStack.index == undoIndex + 1
    after = edgeNames(graph)

    uigraph.undoStack.undo()
    assert edgeNames(graph) == before
    uigraph.undoStack.redo()
    assert edgeNames(graph) == after


def test_insertPrefersSameName(uigraph):
    graph = uigraph.graph
    nodeA, nodeB = (uigraph.addNewNode(FileNode.__name__) for _ in range(2))
    node = uigraph.addNewNode(TwoOutputsNode.__name__)
    graph.addEdge(nodeA.output, nodeB.input)

    assert uigraph.insertionAttributes(node, graph.edge(nodeB.input)) == [node.input, node.output]


def test_insertIncompatible(uigraph):
    graph = uigraph.graph
    nodeA, nodeB = (uigraph.addNewNode(FileNode.__name__) for _ in range(2))
    node = uigraph.addNewNode(IntNode.__name__)
    graph.addEdge(nodeA.output, nodeB.input)
    before = edgeNames(graph)
    undoIndex = uigraph.undoStack.index

    assert not uigraph.insertNodeOnEdge(node, graph.edge(nodeB.input))
    assert edgeNames(graph) == before
    assert uigraph.undoStack.index == undoIndex


def test_insertConnectedNode(uigraph):
    graph = uigraph.graph
    nodeA, nodeB, node, other = (uigraph.addNewNode(FileNode.__name__) for _ in range(4))
    graph.addEdge(nodeA.output, nodeB.input)
    graph.addEdge(other.output, node.input)

    assert not uigraph.insertNodeOnEdge(node, graph.edge(nodeB.input))


def test_insertLocked(uigraph):
    graph = uigraph.graph
    nodeA, nodeB, node = (uigraph.addNewNode(FileNode.__name__) for _ in range(3))
    graph.addEdge(nodeA.output, nodeB.input)
    nodeB.locked = True
    before = edgeNames(graph)

    assert not uigraph.insertNodeOnEdge(node, graph.edge(nodeB.input))
    assert edgeNames(graph) == before


def test_insertForLoop(uigraph):
    graph = uigraph.graph
    nodeA, nodeB, node = (uigraph.addNewNode(FileNode.__name__) for _ in range(3))
    nodeA.inputs.append("a.txt")
    # List element -> single attribute: foreach edge
    graph.addEdge(nodeA.inputs.at(0), nodeB.input)
    before = edgeNames(graph)

    assert not uigraph.insertNodeOnEdge(node, graph.edge(nodeB.input))
    assert edgeNames(graph) == before


def test_insertOnListElement(uigraph):
    graph = uigraph.graph
    nodeA, nodeB, node = (uigraph.addNewNode(FileNode.__name__) for _ in range(3))
    uigraph.addEdge(nodeA.output, nodeB.inputs)
    element = nodeB.inputs.at(0)

    assert uigraph.insertNodeOnEdge(node, graph.edge(element))
    # The list element is kept, now fed by the inserted node
    assert len(nodeB.inputs) == 1
    assert graph.edge(nodeB.inputs.at(0)).src == node.output
    uigraph.undoStack.undo()
    assert graph.edge(nodeB.inputs.at(0)).src == nodeA.output


def test_cutSkipsLockedEdges(uigraph):
    graph = uigraph.graph
    nodeA, nodeB, nodeC = (uigraph.addNewNode(FileNode.__name__) for _ in range(3))
    graph.addEdge(nodeA.output, nodeB.input)
    graph.addEdge(nodeA.output, nodeC.input)
    nodeC.locked = True

    uigraph.deleteEdgesByIndices(list(range(len(graph.edges))))
    assert edgeNames(graph) == [(nodeA.output.fullName, nodeC.input.fullName)]
    uigraph.undoStack.undo()
    assert len(graph.edges) == 2
