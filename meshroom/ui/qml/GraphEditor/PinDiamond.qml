import QtQuick

/**
 * Diamond of a group pin, created by PinShape on the group pins only: a rotated item, since the pin root
 * holding the drop and mouse areas cannot be rotated.
 */

Rectangle {
    property PinShape pin

    // Above the halo, below the other children of the pin (drag preview edge)
    z: -0.5
    anchors.centerIn: parent
    visible: pin.shapeVisible
    width: pin.size / Math.SQRT2
    height: width
    rotation: 45
    radius: 1
    antialiasing: true
    color: pin.fillColor
    border.color: pin.pinColor
    border.width: 1.5
}
