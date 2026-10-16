#!/usr/bin/env python
# coding:utf-8

from meshroom.ui.components.fuzzy import fuzzyMatch, fuzzySearch

NODE_TYPES = [
    "CameraInit", "DepthMap", "DepthMapFilter", "DepthMapRendering", "FeatureExtraction", "FeatureMatching",
    "FeatureRepeatability", "GeometricFilterApplying", "GlobalSfM", "ImageMatching", "ImageMatchingMultiSfM",
    "MeshDecimate", "MeshFiltering", "MeshRemoveUnseenFaces", "Meshing", "MeshroomSceneParameter", "NodalSfM",
    "SfMAlignment", "SfMBootStrapping", "SfMTransform", "StructureFromMotion", "Texturing",
]


def ranking(query):
    return [NODE_TYPES[r["index"]] for r in fuzzySearch(query, NODE_TYPES)]


def test_subsequenceIsRequired():
    assert fuzzyMatch("xyz", "FeatureMatching") is None
    assert fuzzyMatch("mf", "FeatureMatching") is None  # Order matters
    assert fuzzyMatch("", "FeatureMatching") == (0, [])


def test_matchedIndices():
    assert fuzzyMatch("fmatch", "FeatureMatching")[1] == [0, 7, 8, 9, 10, 11]
    assert fuzzyMatch("sfm", "StructureFromMotion")[1] == [0, 9, 13]


def test_expectedRankings():
    assert ranking("fmatch")[0] == "FeatureMatching"
    # An acronym on word starts beats a prefix
    assert ranking("sfm")[0] == "StructureFromMotion"
    # Same score: the shorter name first
    assert ranking("dmap")[:3] == ["DepthMap", "DepthMapFilter", "DepthMapRendering"]
    assert ranking("meshf")[0] == "MeshFiltering"


def test_recentBonus():
    recent = NODE_TYPES.index("DepthMapFilter")
    results = fuzzySearch("dmap", NODE_TYPES, boostedIndices=[recent])
    assert NODE_TYPES[results[0]["index"]] == "DepthMapFilter"


def test_limit():
    assert len(fuzzySearch("m", NODE_TYPES, limit=3)) == 3
