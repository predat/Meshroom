import QtQuick

import Utils 1.0

/**
 * Overview of the graph: one rectangle per node (colored by status, backdrops translucent below)
 * and the rectangle of the current view. Click centers the view on a point, drag pans, wheel zooms.
 * Nodes are drawn from their position and the layout node size: no capture of the graph items.
 */

Rectangle {
    id: root

    property var uigraph: null
    property Item draggable: null  /// Transformed item holding the graph
    property real viewWidth: 0  /// Size of the Graph Editor view
    property real viewHeight: 0

    signal centerRequested(point graphPoint)
    signal zoomRequested(point graphPoint, real factor)

    readonly property var nodes: uigraph && uigraph.graph ? uigraph.graph.nodes : null
    readonly property real nodeWidth: uigraph ? uigraph.layout.nodeWidth : 0
    readonly property real nodeHeight: uigraph ? uigraph.layout.nodeHeight : 0

    // Bounding box of the nodes, and the displayed bounds (with a 10% margin), in graph coordinates
    property rect graphRect: Qt.rect(0, 0, 0, 0)
    property rect bounds: Qt.rect(0, 0, 1, 1)
    readonly property real ratio: Math.min(width / bounds.width, height / bounds.height)
    readonly property real offsetX: (width - bounds.width * ratio) / 2
    readonly property real offsetY: (height - bounds.height * ratio) / 2

    // Current view, in graph coordinates
    readonly property rect viewRect: draggable ? Qt.rect(-draggable.x / draggable.scale, -draggable.y / draggable.scale,
                                                         viewWidth / draggable.scale, viewHeight / draggable.scale)
                                               : Qt.rect(0, 0, 0, 0)
    // Not needed when the whole graph is in the view
    readonly property bool graphInView: viewRect.x <= graphRect.x && viewRect.y <= graphRect.y
                                        && viewRect.x + viewRect.width >= graphRect.x + graphRect.width
                                        && viewRect.y + viewRect.height >= graphRect.y + graphRect.height

    function nodeSize(node) {
        return node.isBackdropNode ? Qt.size(node.nodeWidth, node.nodeHeight) : Qt.size(nodeWidth, nodeHeight)
    }

    /// Recompute the bounds from the nodes: on node addition, removal or move only (deferred with Qt.callLater)
    function updateBounds() {
        if (!nodes || nodes.count === 0) {
            graphRect = Qt.rect(0, 0, 0, 0)
            bounds = Qt.rect(0, 0, 1, 1)
            return
        }
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
        for (let i = 0; i < nodes.count; ++i) {
            const node = nodes.at(i)
            const size = nodeSize(node)
            minX = Math.min(minX, node.x)
            minY = Math.min(minY, node.y)
            maxX = Math.max(maxX, node.x + size.width)
            maxY = Math.max(maxY, node.y + size.height)
        }
        graphRect = Qt.rect(minX, minY, maxX - minX, maxY - minY)
        const marginX = graphRect.width * 0.1
        const marginY = graphRect.height * 0.1
        bounds = Qt.rect(minX - marginX, minY - marginY, Math.max(graphRect.width + 2 * marginX, 1), Math.max(graphRect.height + 2 * marginY, 1))
    }

    function toMinimap(x, y) {
        return Qt.point(offsetX + (x - bounds.x) * ratio, offsetY + (y - bounds.y) * ratio)
    }

    function toGraph(x, y) {
        return Qt.point(bounds.x + (x - offsetX) / ratio, bounds.y + (y - offsetY) / ratio)
    }

    onNodesChanged: Qt.callLater(updateBounds)

    Connections {
        target: root.nodes
        function onCountChanged() { Qt.callLater(root.updateBounds) }
    }

    color: Qt.alpha(GraphTheme.nodeBackground, 0.92)
    border.color: GraphTheme.nodeBorder
    radius: 6
    clip: true

    Repeater {
        model: root.nodes

        delegate: Rectangle {
            required property var object
            required property int index
            readonly property var node: object
            readonly property point position: root.toMinimap(node.x, node.y)
            readonly property size size: root.nodeSize(node)
            readonly property bool selected: root.uigraph.nodeSelection.hasSelection ? root.uigraph.nodeSelection.isRowSelected(index) : false

            x: position.x
            y: position.y
            z: node.isBackdropNode ? 0 : 1
            width: Math.max(size.width * root.ratio, 2)
            height: Math.max(size.height * root.ratio, 2)
            radius: 1
            color: node.isBackdropNode ? Qt.alpha(node.color !== "" ? node.color : GraphTheme.nodeTextSecondary, 0.15)
                                       : (GraphTheme.nodeStatusColors[node.globalStatus] || GraphTheme.nodeStatusColors["NONE"])
            border.width: selected ? 1 : 0
            border.color: GraphTheme.nodeSelection

            Connections {
                target: node
                function onPositionChanged() { Qt.callLater(root.updateBounds) }
                function onInternalAttributesChanged() { if (node.isBackdropNode) Qt.callLater(root.updateBounds) }
            }
        }
    }

    // Current view
    Rectangle {
        readonly property point topLeft: root.toMinimap(root.viewRect.x, root.viewRect.y)
        z: 2
        x: topLeft.x
        y: topLeft.y
        width: root.viewRect.width * root.ratio
        height: root.viewRect.height * root.ratio
        color: Qt.alpha(GraphTheme.nodeSelection, 0.08)
        border.color: GraphTheme.nodeSelection
        border.width: 1.5
        radius: 2
    }

    MouseArea {
        anchors.fill: parent
        z: 3
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        onPressed: function(mouse) { root.centerRequested(root.toGraph(mouse.x, mouse.y)) }
        onPositionChanged: function(mouse) {
            if (pressed)
                root.centerRequested(root.toGraph(mouse.x, mouse.y))
        }
        onWheel: function(wheel) {
            root.zoomRequested(root.toGraph(wheel.x, wheel.y), wheel.angleDelta.y > 0 ? 1.15 : 1 / 1.15)
        }
    }
}
