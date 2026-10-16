"""
Tests for the reset of a group of attributes in a single undo step (UIGraph.resetAttributes).
"""
import pytest

from meshroom.core import desc
from meshroom.core.graph import Graph
from meshroom.ui import commands
from meshroom.ui.graph import UIGraph

from .utils import registeredNodeTypes


class ParamsNode(desc.Node):
    inputs = [
        desc.IntParam(name="count", value=1, range=None),
        desc.FloatParam(name="ratio", value=0.5, range=None),
        desc.StringParam(name="caption", value="a"),
        desc.ListAttribute(name="values", elementDesc=desc.IntParam(name="value", value=0, range=None)),
        desc.IntParam(name="linked", value=0, range=None),
    ]
    outputs = [
        desc.IntParam(name="result", value=0, range=None),
    ]

    def process(self, node):
        pass


class GraphEditing:
    """ The UIGraph editing methods on a core Graph (UIGraph itself needs the Qt backend). """
    push = UIGraph.push
    groupedGraphModification = UIGraph.groupedGraphModification
    removeEdge = UIGraph.removeEdge
    resetAttribute = UIGraph.resetAttribute
    resetAttributes = UIGraph.resetAttributes

    def __init__(self):
        self.graph = self._graph = Graph("")
        self.undoStack = self._undoStack = commands.UndoStack()


@pytest.fixture
def uigraph():
    with registeredNodeTypes([ParamsNode]):
        yield GraphEditing()


def values(node):
    return node.count.value, node.ratio.value, node.caption.value, list(node.values.getPrimitiveValue()), node.linked.value


def test_resetGroupUndoRedo(uigraph):
    graph = uigraph.graph
    source = graph.addNewNode(ParamsNode.__name__)
    node = graph.addNewNode(ParamsNode.__name__)
    for attribute, value in ((node.count, 4), (node.ratio, 2.0), (node.caption, "b"), (node.values, [1, 2])):
        uigraph.push(commands.SetAttributeCommand(graph, attribute, value))
    graph.addEdge(source.result, node.linked)
    modified = values(node)
    undoIndex = uigraph.undoStack.index

    attributes = [node.count, node.ratio, node.caption, node.values, node.linked]
    # The linked attribute is ignored
    assert uigraph.resetAttributes(attributes) == 4
    assert values(node)[:4] == (1, 0.5, "a", [])
    assert node.linked.isLink
    # A single undo step
    assert uigraph.undoStack.index == undoIndex + 1

    uigraph.undoStack.undo()
    assert values(node) == modified
    uigraph.undoStack.redo()
    assert values(node)[:4] == (1, 0.5, "a", [])


def test_resetDefaultIsNoop(uigraph):
    node = uigraph.graph.addNewNode(ParamsNode.__name__)
    undoIndex = uigraph.undoStack.index
    assert uigraph.resetAttributes([node.count, node.ratio]) == 0
    assert uigraph.undoStack.index == undoIndex
