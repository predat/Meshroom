import QtQuick
import QtQuick.Controls
import QtQuick.Shapes 1.6

import GraphEditor 1.0
import Utils 1.0

/**
 * A cubic spline representing an edge, going from point1 to point2, providing mouse interaction.
 */

Item {
    id: root

    property var edge
    property real point1x
    property real point1y
    property real point2x
    property real point2y
    property alias thickness: path.strokeWidth
    property alias color: path.strokeColor
    property bool isForLoop: false
    property int loopSize: 0
    property int iteration: 0
    // State of the data carried by the edge, from its source node: "produced" (solid line), "notProduced" (solid line,
    // opacity 0.55) or "flow" (produced and consumed by a running node: animated dashes, the only dashed state)
    property string dataState: "produced"
    // Crossed by the knife: about to be removed
    property bool cut: false
    // Insertion preview: a node is about to be inserted on this edge
    property bool highlighted: false

    // Edge from an input attribute (or connection preview without edge): long dashes, whatever the data state
    readonly property bool fromInput: !(edge !== undefined && ((edge.src !== undefined && edge.src.isOutput) || edge.dst === undefined))
    readonly property bool isFlowing: !fromInput && dataState === "flow"
    // Dash pattern, in units of the stroke width; scaled down on thick edges to keep the dashes of a 2 px edge.
    // Dashes: knife cut [3, 2], input to input [6, 3], flowing [3, 2] (animated); every other edge is a solid line.
    readonly property real dashScale: 2 / Math.max(thickness, 2)
    readonly property var dashPattern: (cut ? [3, 2] : fromInput ? [6, 3] : [3, 2]).map(v => v * dashScale)
    readonly property int strokeStyle: cut || fromInput || isFlowing ? ShapePath.DashLine : ShapePath.SolidLine

    // Note: edgeArea is destroyed before path, so we need to test if not null to avoid warnings.
    readonly property bool containsMouse: (loopArea && loopArea.containsMouse) || (edgeArea && edgeArea.containsMouse)

    signal pressed(var event)
    signal released(var event)

    x: point1x
    y: point1y
    width: point2x - point1x
    height: point2y - point1y

    property real startX: 0
    property real startY: 0
    property real endX: width
    property real endY: height


    function intersectsSegment(p1, p2) {
        /**
         * Detects whether a line along the given rects diagonal intersects with the edge mouse area.
         */
        // Cheap bounding box rejection first: the curve tangents can exceed the box horizontally by ctrlPtDist
        const marginX = cubic.ctrlPtDist + thickness
        if (Math.max(p1.x, p2.x) < Math.min(x, x + width) - marginX || Math.min(p1.x, p2.x) > Math.max(x, x + width) + marginX ||
            Math.max(p1.y, p2.y) < Math.min(y, y + height) - thickness || Math.min(p1.y, p2.y) > Math.max(y, y + height) + thickness) {
            return false
        }
        // The edgeArea is within the parent Item and its bounds and position are relative to its parent
        // Map the original rect to the coordinates of the edgeArea by subtracting the parent's coordinates from the rect
        // This mapped rect would ensure that the rect coordinates map to 0 of the edge area
        return edgeArea.intersectsSegment(Qt.point(p1.x - x, p1.y - y), Qt.point(p2.x - x, p2.y - y));
    }

    // Insertion preview halo, only instantiated while previewed
    Loader {
        active: root.highlighted
        anchors.fill: parent
        sourceComponent: Shape {
            vendorExtensionsEnabled: false
            ShapePath {
                startX: root.startX
                startY: root.startY
                fillColor: "transparent"
                strokeColor: Qt.alpha(root.color, 0.35)
                strokeWidth: root.thickness + 8
                capStyle: ShapePath.RoundCap
                PathCubic {
                    x: cubic.x
                    y: cubic.y
                    control1X: root.startX + cubic.ctrlPtDist
                    control1Y: root.startY
                    control2X: cubic.control2X
                    control2Y: cubic.control2Y
                }
            }
        }
    }

    Shape {
        anchors.fill: parent
        // Cause rendering artifacts when enabled (and do not support hot reload really well)
        vendorExtensionsEnabled: false
        opacity: !root.cut && !root.fromInput && root.dataState === "notProduced" ? 0.55 : 1.0

        ShapePath {
            id: path
            startX: root.startX
            startY: root.startY
            fillColor: "transparent"

            strokeColor: palette.text
            strokeStyle: root.strokeStyle
            strokeWidth: 1
            dashPattern: root.dashPattern
            capStyle: ShapePath.RoundCap

            // Make the dashes flow from the source to the destination
            NumberAnimation on dashOffset {
                from: root.dashPattern[0] + root.dashPattern[1]
                to: 0
                duration: 500
                loops: Animation.Infinite
                running: root.visible && root.isFlowing
            }

            PathCubic {
                id: cubic
                // Adaptive tangent: wider edges get smoother curves
                property real ctrlPtDist: Math.max(40, Math.abs(x - root.startX) * 0.5)
                x: root.isForLoop ? (root.startX + root.endX) / 2  - loopArea.width / 2 : root.endX
                y: root.isForLoop ? (root.startY + root.endY) / 2 : root.endY
                relativeControl1X: ctrlPtDist
                relativeControl1Y: 0
                control2X: x - ctrlPtDist
                control2Y: y
            }
        }

        ShapePath {
            id: pathSecondary
            startX: (root.startX + root.endX) / 2 + loopArea.width / 2
            startY: (root.startY + root.endY) / 2
            fillColor: "transparent"

            strokeColor: root.isForLoop ? root.color : "transparent"
            strokeStyle: root.strokeStyle
            strokeWidth: root.thickness
            dashPattern: root.dashPattern
            dashOffset: path.dashOffset
            capStyle: ShapePath.RoundCap

            PathCubic {
                id: cubicSecondary
                property real ctrlPtDist: Math.max(40, Math.abs(x - pathSecondary.startX) * 0.5)
                x: root.endX
                y: root.endY
                relativeControl1X: ctrlPtDist
                relativeControl1Y: 0
                control2X: x - ctrlPtDist
                control2Y: y
            }
        }
    }

    Item {
        // Place the label at the middle of the edge
        x: (root.startX + root.endX) / 2
        y: (root.startY + root.endY) / 2
        visible: root.isForLoop

        // Cardinality badge of the foreach loop
        Rectangle {
            anchors.centerIn: parent
            width: badgeLabel.implicitWidth + 12
            height: badgeLabel.implicitHeight + 4
            radius: height / 2
            color: palette.base
            border.color: path.strokeColor
            border.width: 1.5

            Label {
                id: badgeLabel
                anchors.centerIn: parent
                text: "\u00D7" + root.loopSize
                color: palette.text
                font.family: Colors.monoFamily
                font.pointSize: 8
                font.bold: true
            }

            MouseArea {
                id: loopArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.pressed(arguments[0])
                ToolTip.visible: containsMouse
                ToolTip.text: "Foreach Loop: iteration " + (root.iteration + 1) + "/" + root.loopSize
            }
        }
    }

    EdgeMouseArea {
        id: edgeArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        thickness: root.thickness + 4
        curveScale: root.width !== 0 ? cubic.ctrlPtDist / root.width : 0  // Normalize by width
        onPressed: function(event) {
            root.pressed(event)
        }
        onReleased: function(event) {
            root.released(event)
        }

    }
}
