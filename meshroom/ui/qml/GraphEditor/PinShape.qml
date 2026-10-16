import QtQuick

/**
 * Attribute pin: shape by cardinality (circle, square for lists, diamond for groups), colored by data type,
 * with a hover halo and a compatibility ring; flow pins are triangles. It is also the pin anchor: AttributePin puts its drop and mouse
 * areas in it.
 * Pins are instantiated twice per attribute, on every node: circles and squares are drawn by the root itself,
 * and the halo or ring (PinHalo) and the outline (PinOutline) are only created when first needed. The root cannot be rotated (its children
 * would be), so the diamond is an extra rotated item (PinDiamond), only created on the group pins; the flow
 * icon (PinChevron) is only created on the flow pins.
 */

Rectangle {
    id: root

    property color pinColor
    property real size: 10
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
    /// Hide the shape, but keep the anchor (drop and mouse areas)
    property bool shapeVisible: true
    /// Hover halo or compatibility ring, created on first use: most pins are never hovered nor a compatible target
    property Item halo: null
    /// Thin dark outline, for a low contrast on the node body (light or saturated user colors); created when needed
    property bool outlined: false
    property Item outline: null

    readonly property bool diamond: isGroup && !isList
    readonly property color fillColor: filled ? pinColor : halfFilled ? Qt.alpha(pinColor, 0.5) : palette.base
    readonly property bool drawsShape: shapeVisible && !diamond && !isFlow

    width: size
    height: size
    radius: isList ? 2 : width / 2
    antialiasing: true
    color: drawsShape ? fillColor : "transparent"
    border.color: pinColor
    border.width: drawsShape ? 1.5 : 0

    // The cardinality of an attribute and the flow pins do not change: decided once
    Component.onCompleted: {
        ensureOutline()
        if (isFlow)
            Qt.createComponent("PinChevron.qml").createObject(root, { "pin": root })
        else if (diamond)
            Qt.createComponent("PinDiamond.qml").createObject(root, { "pin": root })
    }

    function ensureHalo() {
        if (!halo && (hovered || compatible))
            halo = Qt.createComponent("PinHalo.qml").createObject(root, { "pin": root })
    }

    function ensureOutline() {
        if (!outline && outlined)
            outline = Qt.createComponent("PinOutline.qml").createObject(root, { "pin": root })
    }

    onHoveredChanged: ensureHalo()
    onCompatibleChanged: ensureHalo()
    onOutlinedChanged: ensureOutline()
}
