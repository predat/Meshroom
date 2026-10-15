"""
Tests for the displayable data type (dataType) of attribute descriptors and attributes.
"""
import pytest

import meshroom
from meshroom.core import desc
from meshroom.core.attribute import GroupAttribute, ListAttribute
from meshroom.core.graph import Graph, loadGraph

from .utils import registeredNodeTypes


class NodeWithDataTypes(desc.Node):
    inputs = [
        desc.File(name="input", value=""),
        desc.File(name="custom", value="", dataType="features"),
        desc.ListAttribute(name="featuresFolders", elementDesc=desc.File(name="featuresFolder", value="")),
        desc.GroupAttribute(name="group", items=[desc.IntParam(name="count", value=1)]),
        desc.BoolParam(name="enabledFlag", value=True),
        desc.ChoiceParam(name="choice", value="a", values=["a", "b"]),
    ]
    outputs = [
        desc.File(name="output", value="{nodeCacheFolder}/sfm.abc"),
        desc.File(name="outputFolder", value="{nodeCacheFolder}"),
        desc.File(name="tracks", value="{nodeCacheFolder}/tracksFile.json"),
        desc.File(name="depth", value="{nodeCacheFolder}/<VIEW_ID>_depth.data", semantic="image"),
        desc.File(name="dynamic", value=lambda attr: "{nodeCacheFolder}/out.txt"),
    ]

    def process(self, node):
        pass


@pytest.mark.parametrize("descAttr, expected", [
    (desc.File(name="input", value=""), "file"),
    (desc.File(name="input", value="", dataType="sfmData"), "sfmData"),
    (desc.File(name="sfmData", value=""), "sfmData"),
    (desc.File(name="output", value="{nodeCacheFolder}/sfm.usda"), "sfmData"),
    (desc.File(name="outputMesh", value="{nodeCacheFolder}/mesh.{outputMeshFileTypeValue}"), "mesh"),
    (desc.File(name="output", value="{nodeCacheFolder}/imageMatches.txt"), "imagePairs"),
    (desc.File(name="imagePairsList", value=""), "imagePairs"),
    (desc.File(name="matchesFolder", value=""), "matches"),
    (desc.File(name="masksFolder", value=""), "image"),
    (desc.File(name="output", value="{nodeCacheFolder}"), "folder"),
    (desc.File(name="model", value="", semantic="3d"), "mesh"),
    (desc.File(name="outputData", value="{nodeCacheFolder}/ccheckers.json"), "text"),
    (desc.File(name="tracks", value="{nodeCacheFolder}/tracksFile.json"), "tracks"),
    (desc.ListAttribute(name="matchesFolders", elementDesc=desc.File(name="matchesFolder", value="")), "matches"),
    (desc.GroupAttribute(name="group", items=[desc.IntParam(name="count", value=1)]), "group"),
    (desc.IntParam(name="count", value=1), "scalar"),
    (desc.FloatParam(name="ratio", value=1.0), "scalar"),
    (desc.BoolParam(name="flag", value=True), "scalar"),
    (desc.StringParam(name="text", value=""), "string"),
    (desc.ChoiceParam(name="choice", value="a", values=["a", "b"]), "choice"),
    (desc.ColorParam(name="color", value="#000000"), "color"),
    (desc.PushButtonParam(name="button"), "generic"),
])
def test_descDataType(descAttr, expected):
    assert descAttr.dataType == expected


def test_fileDataTypeOverrideSurvivesClone():
    assert desc.File(name="input", value="", dataType="mesh").clone().dataType == "mesh"


def test_attributeDataType():
    with registeredNodeTypes([NodeWithDataTypes]):
        node = Graph("").addNewNode(NodeWithDataTypes.__name__)
        expected = {
            "input": "file", "custom": "features", "featuresFolders": "features", "group": "group",
            "enabledFlag": "scalar", "choice": "choice", "output": "sfmData", "outputFolder": "folder",
            "tracks": "tracks", "depth": "image", "dynamic": "file",
        }
        for name, dataType in expected.items():
            assert node.attribute(name).dataType == dataType, name
        assert node.attribute("featuresFolders").desc.elementDesc.dataType == "features"


def test_linkedInputTakesSourceDataType():
    with registeredNodeTypes([NodeWithDataTypes]):
        graph = Graph("")
        src = graph.addNewNode(NodeWithDataTypes.__name__)
        dst = graph.addNewNode(NodeWithDataTypes.__name__)
        graph.addEdge(src.attribute("output"), dst.attribute("input"))
        graph.addEdge(src.attribute("output"), dst.attribute("custom"))
        # Generic input: takes the source data type; typed input: keeps its own
        assert dst.attribute("input").dataType == "sfmData"
        assert dst.attribute("custom").dataType == "features"
        graph.removeEdge(dst.attribute("input"))
        assert dst.attribute("input").dataType == "file"


@pytest.mark.parametrize("attributeName, expected", [
    ("CameraInit_1.output", "sfmData"),
    ("ColorCheckerDetection_1.input", "sfmData"),
    ("ColorCheckerDetection_1.outputData", "text"),
    ("ColorCheckerCorrection_1.inputData", "text"),
    ("ColorCheckerCorrection_1.input", "sfmData"),
    ("ColorCheckerCorrection_1.outSfMData", "sfmData"),
])
def test_colorCalibrationDataTypes(attributeName, expected):
    meshroom.core.initNodes()
    meshroom.core.initPipelines()
    if "colorCalibration" not in meshroom.core.pipelineTemplates:
        pytest.skip("'colorCalibration' pipeline template not available")
    graph = loadGraph(meshroom.core.pipelineTemplates["colorCalibration"])
    nodeName, attributeName = attributeName.split(".")
    assert graph.node(nodeName).attribute(attributeName).dataType == expected


def _allAttributes(attributes):
    for attribute in attributes:
        yield attribute
        if isinstance(attribute, (ListAttribute, GroupAttribute)):
            yield from _allAttributes(attribute.value)


@pytest.mark.parametrize("templateName", ["appendTextAndFiles", "photogrammetry"])
def test_templateAttributesHaveDataType(templateName):
    meshroom.core.initNodes()
    meshroom.core.initPipelines()
    if templateName not in meshroom.core.pipelineTemplates:
        pytest.skip(f"'{templateName}' pipeline template not available")
    graph = loadGraph(meshroom.core.pipelineTemplates[templateName])
    assert graph.nodes
    for node in graph.nodes:
        for attribute in _allAttributes(node.attributes):
            assert attribute.dataType, attribute.fullName
