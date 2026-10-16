import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Utils 1.0

/**
 * "● n modified · Reset" for a group of attributes: the modified ones are the inputs which differ from their
 * default value and are not linked (same rule as the node footer). Reset is a single undo step.
 */

RowLayout {
    id: root

    property var attributes: []  /// Attributes of the group (array)
    property bool readOnly: false

    readonly property int modifiedCount: attributes.filter(a => !a.isOutput && !a.isLink && !a.isDefault).length

    visible: modifiedCount > 0
    spacing: 4

    Rectangle {
        implicitWidth: 6
        implicitHeight: 6
        radius: 3
        color: GraphTheme.nodeModified
    }

    Label {
        text: root.modifiedCount + " modified"
        color: GraphTheme.tokenColor(GraphTheme.nodeModified)
        font.family: GraphTheme.fontFamily
        font.pointSize: 8
    }

    Label {
        visible: !root.readOnly
        text: "· Reset"
        color: resetArea.containsMouse ? GraphTheme.nodeSelection : GraphTheme.panelTextSecondary
        font.family: GraphTheme.fontFamily
        font.pointSize: 8
        font.underline: resetArea.containsMouse

        MouseArea {
            id: resetArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: _currentScene.resetAttributes(root.attributes)
        }
        ToolTip.visible: resetArea.containsMouse
        ToolTip.text: "Reset the modified values of this group to their default (linked ones are kept)"
        ToolTip.delay: 500
    }
}
