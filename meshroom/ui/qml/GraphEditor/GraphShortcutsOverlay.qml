import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes

import Utils 1.0

import "GraphShortcuts.js" as GraphShortcuts

/**
 * Help overlay listing the Graph Editor shortcuts by group. Closed by Escape or a click.
 */

Popup {
    id: root

    readonly property var edgeStates: [
        { "description": "Produced data", "opacity": 1.0, "dashes": [], "animated": false },
        { "description": "Data not produced yet", "opacity": GraphTheme.edgeNotProducedOpacity, "dashes": [], "animated": false },
        { "description": "Flowing: consumed by a running node", "opacity": 1.0, "dashes": [3, 2], "animated": true },
        { "description": "Input to input", "opacity": 1.0, "dashes": [6, 3], "animated": false },
    ]

    modal: true
    dim: true
    anchors.centerIn: parent
    padding: 16
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
        color: GraphTheme.nodeBackground
        border.color: GraphTheme.nodeBorder
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
                        color: GraphTheme.nodeText
                        font.family: GraphTheme.fontFamily
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
                                color: GraphTheme.nodeText
                                font.family: GraphTheme.monoFamily
                                font.pointSize: 8
                                Layout.preferredWidth: 170
                            }
                            Label {
                                text: modelData.description
                                color: GraphTheme.nodeTextSecondary
                                font.family: GraphTheme.fontFamily
                                font.pointSize: 9
                            }
                        }
                    }

                    // Edges legend: the data states (Edge.qml), with a sample of each
                    Repeater {
                        model: modelData === "Edges" ? root.edgeStates : []

                        RowLayout {
                            spacing: 12
                            Shape {
                                Layout.preferredWidth: 170
                                Layout.preferredHeight: 10
                                vendorExtensionsEnabled: false
                                opacity: modelData.opacity
                                ShapePath {
                                    startX: 0
                                    startY: 5
                                    strokeColor: GraphTheme.dataTypeColor("sfmData")
                                    strokeWidth: 2
                                    fillColor: "transparent"
                                    capStyle: ShapePath.RoundCap
                                    strokeStyle: modelData.dashes.length > 0 ? ShapePath.DashLine : ShapePath.SolidLine
                                    dashPattern: modelData.dashes.length > 0 ? modelData.dashes : [1, 0]
                                    // Only runs while the help is shown
                                    NumberAnimation on dashOffset {
                                        from: 5
                                        to: 0
                                        duration: 500
                                        loops: Animation.Infinite
                                        running: root.visible && modelData.animated
                                    }
                                    PathLine { x: 60; y: 5 }
                                }
                            }
                            Label {
                                text: modelData.description
                                color: GraphTheme.nodeTextSecondary
                                font.family: GraphTheme.fontFamily
                                font.pointSize: 9
                            }
                        }
                    }
                }
            }
        }
    }
}
