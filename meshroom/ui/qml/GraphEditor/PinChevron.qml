import QtQuick

import MaterialIcons 2.2

/**
 * Icon of a node header flow pin (flowInputs/flowOutput), created by PinShape on the flow pins only.
 */

MaterialLabel {
    property PinShape pin

    anchors.centerIn: parent
    visible: pin.shapeVisible
    text: pin.filled ? MaterialIcons.play_arrow : MaterialIcons.chevron_right
    font.pointSize: 10
    color: pin.pinColor
}
