import QtQuick

/**
 * Thin dark outline of a pin of a low contrast on its node body (light or saturated user colors), created by
 * PinShape on these pins only.
 */

Rectangle {
    property PinShape pin
    // Below the shape and the diamond, above the halo
    z: -0.75
    anchors.centerIn: parent
    visible: pin.shapeVisible && pin.outlined && !pin.isFlow
    width: (pin.diamond ? pin.size / Math.SQRT2 : pin.size) + 2
    height: width
    rotation: pin.diamond ? 45 : 0
    radius: pin.diamond ? 1.5 : pin.isList ? 3 : width / 2
    antialiasing: true
    color: "transparent"
    border.color: Qt.rgba(0, 0, 0, 0.6)
    border.width: 1
}
