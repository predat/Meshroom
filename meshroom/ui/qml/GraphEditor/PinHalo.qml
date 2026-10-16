import QtQuick

/**
 * Hover halo (3 px), or else compatibility ring (1.5 px, thin enough not to merge with the neighbour pins' ones)
 * of a pin, created by PinShape the first time the pin is hovered or a compatible drop target.
 */

Rectangle {
    property PinShape pin
    readonly property real outer: pin.size + (pin.hovered ? 6 : 4)

    z: -1
    anchors.centerIn: parent
    visible: pin.shapeVisible && (pin.hovered || pin.compatible)
    width: pin.diamond ? outer / Math.SQRT2 : outer
    height: width
    rotation: pin.diamond ? 45 : 0
    radius: pin.diamond ? 1 : pin.isList ? 2 : width / 2
    antialiasing: true
    color: pin.hovered ? Qt.alpha(pin.pinColor, 0.35) : "transparent"
    border.color: pin.pinColor
    border.width: pin.hovered ? 0 : 1.5
}
