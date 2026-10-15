import QtQuick

import MaterialIcons 2.2

/**
 * Visual of an attribute pin: shape by cardinality (circle, square for lists, diamond for groups),
 * colored by data type, with a hover halo and a compatibility ring. Flow pins are triangles.
 */

Item {
    id: root

    property color color
    property bool isList: false
    property bool isGroup: false
    /// Node header flow pin (flowInputs/flowOutput): triangle
    property bool isFlow: false
    /// Connected: filled shape; children connected under a collapsed group: half-filled
    property bool filled: false
    property bool halfFilled: false
    property bool hovered: false
    /// Compatible target of the edge being dragged
    property bool compatible: false

    width: 10
    height: width

    component Figure: Rectangle {
        property real size: root.width
        readonly property bool diamond: root.isGroup && !root.isList

        anchors.centerIn: parent
        width: diamond ? size / Math.SQRT2 : size
        height: width
        rotation: diamond ? 45 : 0
        radius: diamond ? 1 : root.isList ? 2 : width / 2
        antialiasing: true
    }

    // Hover halo (3 px)
    Figure {
        size: root.width + 6
        visible: root.hovered
        color: Qt.alpha(root.color, 0.35)
    }

    // Compatibility ring (1.5 px), thin enough not to merge with the neighbour pins' ones
    Figure {
        size: root.width + 4
        visible: root.compatible && !root.hovered
        color: "transparent"
        border.color: root.color
        border.width: 1.5
    }

    Figure {
        visible: !root.isFlow
        color: root.filled ? root.color : root.halfFilled ? Qt.alpha(root.color, 0.5) : palette.base
        border.color: root.color
        border.width: 1.5
    }

    MaterialLabel {
        visible: root.isFlow
        anchors.centerIn: parent
        text: root.filled ? MaterialIcons.play_arrow : MaterialIcons.chevron_right
        font.pointSize: 10
        color: root.color
    }
}
