import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Utils 1.0

import "GraphShortcuts.js" as GraphShortcuts

/**
 * Help overlay listing the Graph Editor shortcuts by group. Closed by Escape or a click.
 */

Popup {
    id: root

    modal: true
    dim: true
    anchors.centerIn: parent
    padding: 16
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
        color: Colors.nodeBackground
        border.color: Colors.nodeBorder
        radius: 8
    }

    contentItem: Item {
        implicitWidth: grid.implicitWidth
        implicitHeight: grid.implicitHeight

        // A click inside closes the overlay too
        TapHandler { onTapped: root.close() }

        GridLayout {
            id: grid
            columns: 2
            columnSpacing: 32
            rowSpacing: 16

            Repeater {
                model: GraphShortcuts.groups

                ColumnLayout {
                    Layout.alignment: Qt.AlignTop
                    spacing: 4

                    Label {
                        text: modelData
                        color: Colors.nodeText
                        font.family: Colors.fontFamily
                        font.pointSize: 10
                        font.bold: true
                        Layout.bottomMargin: 2
                    }

                    Repeater {
                        model: GraphShortcuts.shortcuts.filter(s => s.group === modelData)

                        RowLayout {
                            spacing: 12
                            Label {
                                text: modelData.keys
                                color: Colors.nodeText
                                font.family: Colors.monoFamily
                                font.pointSize: 8
                                Layout.preferredWidth: 170
                            }
                            Label {
                                text: modelData.description
                                color: Colors.nodeTextSecondary
                                font.family: Colors.fontFamily
                                font.pointSize: 9
                            }
                        }
                    }
                }
            }
        }
    }
}
