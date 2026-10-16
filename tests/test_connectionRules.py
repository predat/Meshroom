"""
Tests for the rules deciding whether an edge dragged from a pin can be dropped on another pin.
"""
from meshroom.core import desc
from meshroom.core.graph import Graph
from meshroom.ui.graph import connectionError, connectionTargets

from .utils import registeredNodeTypes


class NodeWithConnectors(desc.Node):
    inputs = [
        desc.File(name="input", value=""),
        desc.IntParam(name="count", value=1),
        desc.ListAttribute(name="inputs", elementDesc=desc.File(name="file", value="")),
    ]
    outputs = [
        desc.File(name="output", value="{nodeCacheFolder}/out.txt"),
    ]

    def process(self, node):
        pass


def _createNodes():
    graph = Graph("")
    return graph, graph.addNewNode(NodeWithConnectors.__name__), graph.addNewNode(NodeWithConnectors.__name__)


def test_validConnections():
    with registeredNodeTypes([NodeWithConnectors]):
        _, nodeA, nodeB = _createNodes()
        # Output pin dragged on an input pin
        assert connectionError(nodeA.output, "output", nodeB.input, "input") == ""
        # Input pin dragged on an output pin (the edge goes from the output to the input)
        assert connectionError(nodeB.input, "input", nodeA.output, "output") == ""
        # Input-to-input edge: input dragged on the output pin of another input
        assert connectionError(nodeB.input, "input", nodeA.input, "output") == ""
        # List to list
        assert connectionError(nodeA.inputs, "output", nodeB.inputs, "input") == ""


def test_refusedConnections():
    with registeredNodeTypes([NodeWithConnectors]):
        graph, nodeA, nodeB = _createNodes()
        assert connectionError(nodeA.output, "output", nodeB.output, "output") == "same direction"
        assert connectionError(nodeA.output, "output", nodeA.input, "input") == "same node"
        assert connectionError(nodeA.output, "output", nodeB.count, "input") == "incompatible type"
        # A simple attribute cannot be the source of a list
        assert connectionError(nodeB.input, "input", nodeA.inputs, "output") == "incompatible type"

        nodeB.inputs.append("/some/file")
        assert connectionError(nodeA.inputs, "output", nodeB.inputs, "input") == "list already filled"

        nodeB.locked = True
        assert connectionError(nodeA.output, "output", nodeB.input, "input") == "locked"


def test_connectionTargets():
    with registeredNodeTypes([NodeWithConnectors]):
        graph, nodeA, nodeB = _createNodes()
        targets = connectionTargets(graph, nodeA.output, "output")
        assert set(targets["attributes"]) == {nodeB.input.uuid, nodeB.inputs.uuid}
        assert targets["nodes"] == [nodeB.name]

        targets = connectionTargets(graph, nodeA.input, "input")
        assert set(targets["attributes"]) == {nodeB.input.uuid, nodeB.output.uuid}
        assert targets["nodes"] == [nodeB.name]
