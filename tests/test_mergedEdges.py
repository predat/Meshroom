"""
Tests for the edges merged by pair of nodes, drawn in the Graph Editor overview.
"""
from meshroom.core import desc
from meshroom.core.graph import Graph
from meshroom.ui.graph import mergeEdges

from .utils import registeredNodeTypes


class NodeWithTwoPaths(desc.Node):
    inputs = [
        desc.File(name="first", value=""),
        desc.File(name="second", value=""),
    ]
    outputs = [
        desc.File(name="output", value="{nodeCacheFolder}/out.txt"),
    ]

    def process(self, node):
        pass


def test_mergeEdges():
    with registeredNodeTypes([NodeWithTwoPaths]):
        graph = Graph("")
        nodeA = graph.addNewNode(NodeWithTwoPaths.__name__)
        nodeB = graph.addNewNode(NodeWithTwoPaths.__name__)
        nodeC = graph.addNewNode(NodeWithTwoPaths.__name__)
        graph.addEdge(nodeA.output, nodeB.first)
        graph.addEdge(nodeA.output, nodeB.second)
        graph.addEdge(nodeB.output, nodeC.first)
        # Input-to-input edge: merged with the edges of its pair as well
        graph.addEdge(nodeA.first, nodeC.second)

        merged = mergeEdges(graph.edges.values())
        assert merged == {(nodeA, nodeB): 2, (nodeB, nodeC): 1, (nodeA, nodeC): 1}
        assert sum(merged.values()) == len(graph.edges)

        graph.removeEdge(nodeB.second)
        assert mergeEdges(graph.edges.values())[(nodeA, nodeB)] == 1
