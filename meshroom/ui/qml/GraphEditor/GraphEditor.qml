import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes

import Controls 1.0
import MaterialIcons 2.2
import Utils 1.0

import "GraphShortcuts.js" as GraphShortcuts

/**
 * A component displaying a Graph (nodes, attributes and edges).
 */

Item {
    id: root

    property variant uigraph: null  /// Meshroom UI graph (UIGraph)
    readonly property variant graph: uigraph ? uigraph.graph : null  /// Core graph contained in the UI graph
    property variant nodeTypesModel: null  /// The list of node types that can be instantiated
    property real maxZoom: 2.0
    property real minZoom: 0.1
    property var edgeAboutToBeRemoved: undefined

    property var _attributeToDelegate: ({})
    property var _nodeToDelegate: new Map()

    /// Level of detail of the nodes, from the zoom: 0 = full, 1 = structure (header only), 2 = overview (pill)
    property int lod: 0
    readonly property real lodHysteresis: 0.02

    function updateLod() {
        /*
         * Updates the level of detail from the zoom, with an hysteresis around each threshold:
         * a zoom going back and forth around a threshold does not switch the level each time.
         */
        if (!GraphEditorSettings.semanticZoom) {
            lod = 0
            return
        }
        const zoom = draggable.scale
        const structure = GraphEditorSettings.lodStructureThreshold
        const overview = GraphEditorSettings.lodOverviewThreshold
        const h = lodHysteresis
        if (lod === 0)
            lod = zoom < overview - h ? 2 : zoom < structure - h ? 1 : 0
        else if (lod === 1)
            lod = zoom >= structure + h ? 0 : zoom < overview - h ? 2 : 1
        else
            lod = zoom >= structure + h ? 0 : zoom >= overview + h ? 1 : 2
    }

    Connections {
        target: GraphEditorSettings
        function onSemanticZoomChanged() { root.updateLod() }
        function onLodStructureThresholdChanged() { root.updateLod() }
        function onLodOverviewThresholdChanged() { root.updateLod() }
    }

    /// Footprint of a node delegate: the constant layout size for nodes, whatever their level of detail
    function footprint(item) {
        return Qt.rect(item.x, item.y, item.width, item.isBackdropNode ? item.height : item.footprintHeight)
    }

    /// Animated zoom at 1.0, centered on a node delegate
    function zoomToNode(item) {
        const rect = footprint(item)
        zoomAnimation.toX = root.width / 2 - (rect.x + rect.width / 2)
        zoomAnimation.toY = root.height / 2 - (rect.y + rect.height / 2)
        zoomAnimation.restart()
    }

    ParallelAnimation {
        id: zoomAnimation
        property real toX: 0
        property real toY: 0
        NumberAnimation { target: draggable; property: "scale"; to: 1.0; duration: 300; easing.type: Easing.OutCubic }
        NumberAnimation { target: draggable; property: "x"; to: zoomAnimation.toX; duration: 300; easing.type: Easing.OutCubic }
        NumberAnimation { target: draggable; property: "y"; to: zoomAnimation.toY; duration: 300; easing.type: Easing.OutCubic }
    }

    // Names of the nodes whose edges are highlighted: the hovered node, or else the selected nodes
    property var activeNodeNames: new Set()

    function updateActiveNodeNames() {
        const names = new Set()
        if (uigraph && uigraph.hoveredNode) {
            names.add(uigraph.hoveredNode.name)
        } else if (uigraph) {
            uigraph.nodeSelection.selectedIndexes.forEach(function(idx) {
                names.add(uigraph.graph.nodes.at(idx.row).name)
            })
        }
        activeNodeNames = names
    }

    onGraphChanged: updateActiveNodeNames()

    Connections {
        target: uigraph
        function onHoveredNodeChanged() { root.updateActiveNodeNames() }
    }

    Connections {
        target: uigraph ? uigraph.nodeSelection : null
        function onSelectionChanged() { root.updateActiveNodeNames() }
    }

    // Edge being dragged from a pin (null otherwise), the item following its tip,
    // and the attributes/nodes it can be connected to, computed once per drag
    property var draggedAttribute: null
    property string draggedConnectorType: ""
    property var draggedItem: null
    property var compatibleAttributeUuids: null
    property var compatibleNodeNames: null
    // Pin under the dragged edge, and the reason why the connection is refused ("" if valid)
    property var dropTargetAttribute: null
    property string dropTargetReason: ""

    function setConnectionDrag(attribute, connectorType, dragItem) {
        // The compatible sets are only set while draggedAttribute is: bindings may rely on it
        compatibleAttributeUuids = null
        compatibleNodeNames = null
        dropTargetAttribute = null
        dropTargetReason = ""
        draggedConnectorType = connectorType
        draggedItem = dragItem
        draggedAttribute = attribute
        if (attribute) {
            const targets = uigraph.connectionTargets(attribute, connectorType)
            compatibleAttributeUuids = new Set(targets.attributes)
            compatibleNodeNames = new Set(targets.nodes)
        }
    }

    // Knife: K held + drag cuts the crossed edges (Ctrl+Alt+drag is an alias)
    property bool knifeKeyHeld: false
    onActiveFocusChanged: if (!activeFocus) knifeKeyHeld = false

    function isEdgeLocked(edge) {
        return edge.dst.node.locked || edge.dst.isReadOnly
    }

    // Edges crossed by the knife: removable and locked counts, and the "src>dst" node pairs (merged edges)
    readonly property var knifeHits: {
        const hits = { "count": 0, "locked": 0, "pairs": new Set() }
        for (const index of edgeSelectionLine.hitIndices) {
            const edge = edgesRepeater.itemAt(index).edge
            if (isEdgeLocked(edge)) {
                hits.locked++
                continue
            }
            hits.count++
            hits.pairs.add(edge.src.node.name + ">" + edge.dst.node.name)
        }
        return hits
    }

    // Insertion on an edge: the edge under a node (with the uuids of the attributes to connect),
    // previewed once hovered for 150 ms
    property var insertCandidate: null
    property var insertPreview: null

    /// First edge crossed by one of the segments ([p1, p2], in draggable coordinates) on which node can be inserted
    function insertionAt(node, segments) {
        for (let i = 0; i < edgesRepeater.count; ++i) {
            const item = edgesRepeater.itemAt(i)
            if (!item || !item.isValidEdge || !segments.some(s => item.intersectsSegment(s[0], s[1])))
                continue
            const attributes = uigraph.insertionAttributes(node, item.edge)
            if (attributes.length > 0) {
                const uuids = [item.edge.src.uuid, item.edge.dst.uuid, attributes[0].uuid, attributes[1].uuid]
                return { "edge": item.edge, "uuids": new Set(uuids) }
            }
        }
        return null
    }

    /// Track the edge under the single dragged node, crossed by one of its diagonals
    function updateInsertCandidate(nodeItem) {
        let found = null
        if (GraphEditorSettings.insertOnEdge && lod < 2 && uigraph.nodeSelection.selectedIndexes.length === 1) {
            const r = Qt.rect(nodeItem.x, nodeItem.y, nodeItem.width, nodeItem.height)
            found = insertionAt(nodeItem.node, [[Qt.point(r.x, r.y), Qt.point(r.x + r.width, r.y + r.height)],
                                                [Qt.point(r.x + r.width, r.y), Qt.point(r.x, r.y + r.height)]])
        }
        if ((found ? found.edge : null) === (insertCandidate ? insertCandidate.edge : null))
            return
        insertCandidate = found
        insertPreview = null
        if (found)
            insertTimer.restart()
        else
            insertTimer.stop()
    }

    function clearInsertion() {
        insertTimer.stop()
        insertCandidate = null
        insertPreview = null
    }

    /// Insert a node created at position on the edge under it (8 px screen tolerance), if any
    function insertCreatedNode(node, position) {
        if (!GraphEditorSettings.insertOnEdge)
            return
        const t = 8 / draggable.scale
        const insertion = insertionAt(node, [[Qt.point(position.x - t, position.y), Qt.point(position.x + t, position.y)],
                                             [Qt.point(position.x, position.y - t), Qt.point(position.x, position.y + t)]])
        if (insertion)
            uigraph.insertNodeOnEdge(node, insertion.edge)
    }

    // Only runs while a node is dragged over an edge
    Timer {
        id: insertTimer
        interval: 150
        onTriggered: root.insertPreview = root.insertCandidate
    }

    // Signals
    signal workspaceMoved()
    signal workspaceClicked()

    signal nodeDoubleClicked(var mouse, var node)
    signal computeRequest(var nodes)
    signal submitRequest(var nodes)

    property int nbMeshroomScenes: 0
    property int nbDraggedFiles: 0
    signal filesDropped(var drop, var mousePosition)  // Files have been dropped

    // Trigger initial fit() after initialization
    // (ensure GraphEditor has its final size)
    Component.onCompleted: firstFitTimer.start()

    Timer {
        id: firstFitTimer
        running: false
        interval: 10
        onTriggered: fit()
    }

    clip: true

    SystemPalette { id: activePalette }

    /// Get node delegate for the given node object
    function nodeDelegate(node) {
        return _nodeToDelegate.get(node)
    }

    /// Get the InputNode delegate at the given position in 'draggable' coordinates, or null
    function inputNodeDelegateAt(draggableX, draggableY) {
        for (var i = 0; i < nodeRepeater.count; ++i) {
            var delegate = nodeRepeater.getItemAt(i)
            if (delegate && delegate.node && delegate.node.isInputNode && !delegate.readOnly) {
                if (draggableX >= delegate.x && draggableX <= delegate.x + delegate.width &&
                    draggableY >= delegate.y && draggableY <= delegate.y + delegate.height) {
                    return delegate
                }
            }
        }
        return null
    }

    /// Duplicate a node and optionally all the following ones
    function duplicateNode(duplicateFollowingNodes) {
        var nodes
        if (duplicateFollowingNodes) {
            nodes = uigraph.duplicateNodesFrom(uigraph.getSelectedNodes())
        } else {
            nodes = uigraph.duplicateNodes(uigraph.getSelectedNodes())
        }
        uigraph.selectedNode = nodes[0]
        uigraph.selectNodes(nodes)
    }

    /// Copy node content to clipboard
    function copyNodes() {
        var nodeContent = uigraph.getSelectedNodesContent()
        if (nodeContent !== '') {
            Clipboard.clear()
            Clipboard.setText(nodeContent)
        }
    }

    /// Paste content of clipboard to graph editor and create new node if valid
    function pasteNodes() {
        let finalPosition = undefined
        if (mouseArea.containsMouse) {
            finalPosition = mapToItem(draggable, mouseArea.mouseX, mouseArea.mouseY)
        } else {
            finalPosition = getCenterPosition()
        }

        const copiedContent = Clipboard.getText()
        const nodes = uigraph.pasteNodes(copiedContent, finalPosition)
        if (nodes.length > 0) {
            uigraph.selectedNode = nodes[0]
            uigraph.selectNodes(nodes)
        }
    }

    /// Get the coordinates of the point at the center of the GraphEditor
    function getCenterPosition() {
        return mapToItem(draggable, mouseArea.width / 2, mouseArea.height / 2)
    }

    /// Open the command palette; created nodes go at the cursor if it is over the graph, at the center otherwise
    function openCommandPalette(createMode) {
        commandPalette.spawnPosition = mouseArea.containsMouse ? mouseArea.mapToItem(draggable, mouseArea.mouseX, mouseArea.mouseY)
                                                               : getCenterPosition()
        commandPalette.openPalette(createMode)
    }

    /// Create a node at position (in draggable coordinates), inserted on the edge under it if any, and select it
    function createNode(nodeType, position) {
        // Creation and insertion on the edge under the spawn position: a single undo step
        uigraph.beginModification("Create " + nodeType)
        const node = uigraph.addNewNode(nodeType, position)
        insertCreatedNode(node, position)
        uigraph.endModification()
        uigraph.selectedNode = node
        uigraph.selectNodes([node])
    }

    function importPipeline(pipeline, position) {
        const url = MeshroomApp.pipelineTemplateFiles[MeshroomApp.pipelineTemplateNames.indexOf(pipeline)]["path"]
        const nodes = uigraph.importProject(Filepath.stringToUrl(url), position)
        uigraph.selectedNode = nodes[0]
        uigraph.selectNodes(nodes)
    }

    /// Zoom by factor (clamped to the zoom range) around the point (x, y) of the view
    function zoomAt(x, y, factor) {
        const scale = Math.min(Math.max(minZoom, draggable.scale * factor), maxZoom)
        if (draggable.scale == scale)
            return
        const point = mapToItem(draggable, x, y)
        const zoomFactor = scale / draggable.scale
        draggable.x += (1 - zoomFactor) * point.x * draggable.scale
        draggable.y += (1 - zoomFactor) * point.y * draggable.scale
        draggable.scale = scale
        workspaceMoved()
    }

    /// Center the view on a point of the graph (draggable coordinates)
    function centerOn(point) {
        draggable.x = root.width / 2 - point.x * draggable.scale
        draggable.y = root.height / 2 - point.y * draggable.scale
        workspaceMoved()
    }

    /// Fit a node delegate in the view, zoom limited to prevent huge text
    function fitNode(nodeItem) {
        const bbox = footprint(nodeItem)
        draggable.scale = Math.min(Math.min(root.width / bbox.width, root.height / bbox.height), maxZoom)
        draggable.x = bbox.x * draggable.scale * -1 + (root.width - bbox.width * draggable.scale) * 0.5
        draggable.y = bbox.y * draggable.scale * -1 + (root.height - bbox.height * draggable.scale) * 0.5
    }

    /// Add a backdrop around the selected nodes, or at the center of the view
    function addBackdrop() {
        var selectedNodes = uigraph.getSelectedNodes()
        var backdrop
        if (selectedNodes.length > 0) {
            // Calculate bounding box of selected nodes
            var padding = uigraph.layout.gridSpacing * 0.5
            var minX = Number.MAX_VALUE
            var minY = Number.MAX_VALUE
            var maxX = -Number.MAX_VALUE
            var maxY = -Number.MAX_VALUE
            for (var i = 0; i < selectedNodes.length; i++) {
                var n = selectedNodes[i]
                // Node footprint, constant whatever the level of detail (actual size for backdrops)
                var item = nodeDelegate(n)
                var nw = item ? item.width : uigraph.layout.nodeWidth
                var nh = item ? footprint(item).height : uigraph.layout.nodeHeight
                minX = Math.min(minX, n.x)
                minY = Math.min(minY, n.y)
                maxX = Math.max(maxX, n.x + nw)
                maxY = Math.max(maxY, n.y + nh)
            }
            var bboxX = minX - padding
            var bboxY = minY - 2 * padding  // minus padding and title bar height
            var bboxW = Math.round(maxX - minX + 2 * padding)
            var bboxH = Math.round(maxY - minY + 2 * padding)
            backdrop = uigraph.addBackdropNode(Qt.point(bboxX, bboxY), bboxW, bboxH)
        } else {
            backdrop = uigraph.addNewNode("Backdrop", getCenterPosition())
        }
        uigraph.selectedNode = backdrop
        uigraph.selectNodes([backdrop])
    }

    /// Run a command palette action (GraphShortcuts entries with a "command" label)
    function runAction(action) {
        switch (action) {
            case "fit": fit(); break
            case "help": shortcutsOverlay.open(); break
            case "duplicate": duplicateNode(false); break
            case "remove": uigraph.removeSelectedNodes(); break
            case "disconnect": uigraph.disconnectSelectedNodes(); break
            case "autoLayout": uigraph.layout.reset(); break
            // An empty node list would mean the whole graph
            case "compute": if (uigraph.nodeSelection.hasSelection) computeRequest(uigraph.getSelectedNodes()); break
            case "submit": if (uigraph.nodeSelection.hasSelection) submitRequest(uigraph.getSelectedNodes()); break
            case "addBackdrop": addBackdrop(); break
            case "alignVertically": uigraph.alignVertically(); break
            case "alignHorizontally": uigraph.alignHorizontally(); break
            case "minimap": GraphEditorSettings.showMinimap = !GraphEditorSettings.showMinimap; break
            case "zoomReset": zoomAt(root.width / 2, root.height / 2, 1 / draggable.scale); break
            case "selectErrors": {
                const nodes = []
                for (let i = 0; i < graph.nodes.count; ++i) {
                    if (graph.nodes.at(i).globalStatus === "ERROR")
                        nodes.push(graph.nodes.at(i))
                }
                uigraph.selectNodes(nodes)
                if (nodes.length > 0) {
                    uigraph.selectedNode = nodes[0]
                    fit()
                }
                break
            }
            default: console.warn("Unknown Graph Editor action: " + action)
        }
    }

    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_F) {
            fit()
        } else if (event.key === Qt.Key_Delete) {
            if (event.modifiers === Qt.AltModifier) {
                uigraph.removeNodesFrom(uigraph.getSelectedNodes())
            } else {
                uigraph.removeSelectedNodes()
            }
        } else if (event.key === Qt.Key_D) {
            duplicateNode(event.modifiers === Qt.AltModifier)
        } else if (event.key === Qt.Key_X) {
            if (event.modifiers === Qt.ControlModifier) {
                copyNodes()
                uigraph.removeSelectedNodes()
            }
            else {
                uigraph.disconnectSelectedNodes()
            }
        } else if (event.key === Qt.Key_C) {
            if (event.modifiers === Qt.ControlModifier) {
                copyNodes()
            }
            else {
                colorSelector.toggle()
            }
        } else if (event.key === Qt.Key_V && event.modifiers === Qt.ControlModifier) {
            pasteNodes()
        } else if (event.key === Qt.Key_V && event.modifiers === Qt.ShiftModifier) {
            uigraph.alignVertically()
        } else if (event.key === Qt.Key_H && event.modifiers === Qt.ShiftModifier) {
            uigraph.alignHorizontally()
        } else if (event.key === Qt.Key_Tab) {
            event.accepted = true
            openCommandPalette(false)
        } else if (event.key === Qt.Key_K) {
            if (!event.isAutoRepeat)
                knifeKeyHeld = true
        } else if (event.key === Qt.Key_Escape) {
            if (edgeSelectionLine.active) {
                edgeSelectionLine.cancelSelection()
                mouseArea.removingEdges = false
            }
        } else if (event.key === Qt.Key_Question || (event.key === Qt.Key_Slash && event.modifiers & Qt.ShiftModifier)) {
            shortcutsOverlay.open()
        }
    }

    Keys.onReleased: function(event) {
        if (event.key === Qt.Key_K && !event.isAutoRepeat) {
            knifeKeyHeld = false
        }
    }

    GraphShortcutsOverlay {
        id: shortcutsOverlay
        onClosed: root.forceActiveFocus()
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        property double factor: 1.15
        property bool removingEdges: false
        // Activate multisampling for edges antialiasing
        layer.enabled: true
        layer.samples: 8

        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        drag.threshold: 0
        drag.smoothed: false
        cursorShape: drag.target == draggable ? Qt.ClosedHandCursor : removingEdges || root.knifeKeyHeld ? Qt.CrossCursor : Qt.ArrowCursor

        onWheel: function(wheel) {
            root.zoomAt(wheel.x, wheel.y, wheel.angleDelta.y > 0 ? factor : 1 / factor)
        }

        onPressed: function(mouse) {
            // Knife: K held or Ctrl+Alt
            if (mouse.button == Qt.LeftButton && (root.knifeKeyHeld || ((mouse.modifiers & Qt.ControlModifier) && (mouse.modifiers & Qt.AltModifier)))) {
                edgeSelectionLine.startSelection(mouse)
                removingEdges = true
                root.forceActiveFocus()
                return
            }
            if (mouse.button != Qt.MiddleButton && mouse.modifiers == Qt.NoModifier) {
                uigraph.clearNodeSelection()
            }
            if (mouse.button == Qt.LeftButton && (mouse.modifiers == Qt.NoModifier || mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))) {
                nodeSelectionBox.startSelection(mouse)
            }
            if (mouse.button == Qt.MiddleButton || (mouse.button == Qt.LeftButton && mouse.modifiers & Qt.AltModifier)) {
                drag.target = draggable // start drag
            }
        }

        onReleased: {
            removingEdges = false
            edgeSelectionLine.endSelection()
            nodeSelectionBox.endSelection()
            drag.target = null
            root.forceActiveFocus()
            workspaceClicked()
        }

        onPositionChanged: {
            if (drag.active)
                workspaceMoved()
        }

        onClicked: function(mouse) {
            if (mouse.button == Qt.RightButton) {
                // Create mode: the node is created at the click position
                commandPalette.spawnPosition = mouseArea.mapToItem(draggable, mouse.x, mouse.y)
                commandPalette.openPalette(true)
            }
        }

        // Informative contextual menu when graph is read-only
        Menu {
            id: lockedMenu
            MenuItem {
                id: item
                font.pointSize: 8
                enabled: false
                text: "Computing - Graph is Locked!"
            }
        }

        Canvas {
            id: templateBackgroundStripes

            anchors.fill: parent
            visible: Boolean(root.graph && root.graph.templateFilepath)
            opacity: 0.03

            readonly property color stripeColor: activePalette.highlight
            readonly property int stripeWidth: 21
            readonly property int stripeGap: 42

            onPaint: {
                const ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)

                if (!visible) {
                    return
                }

                ctx.save()
                ctx.strokeStyle = stripeColor
                ctx.lineWidth = stripeWidth

                const diagonal = Math.sqrt(width * width + height * height)
                const step = stripeWidth + stripeGap
                ctx.translate(width * 0.5, height * 0.5)
                ctx.rotate(-Math.PI / 4)

                for (let x = -diagonal; x <= diagonal; x += step) {
                    ctx.beginPath()
                    ctx.moveTo(x, -diagonal)
                    ctx.lineTo(x, diagonal)
                    ctx.stroke()
                }

                ctx.restore()
            }

            onVisibleChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onStripeColorChanged: requestPaint()
        }

        Item {
            id: draggable
            transformOrigin: Item.TopLeft
            width: 1000
            height: 1000

            onScaleChanged: root.updateLod()

            Popup {
                id: edgeMenu
                property var currentEdge: null
                property bool forLoop: false

                onOpened: {
                    expandButton.canExpand = uigraph.canExpandForLoop(edgeMenu.currentEdge)
                }

                contentItem: Row {
                    IntSelector {
                        id: loopIterationSelector
                        tooltipText: "Iterations"
                        visible: edgeMenu.currentEdge && edgeMenu.forLoop

                        enabled: expandButton.canExpand

                        property var listAttr: edgeMenu.currentEdge ? edgeMenu.currentEdge.src.root : null

                        Connections {
                            target: edgeMenu
                            function onCurrentEdgeChanged() {
                                if (edgeMenu.currentEdge) {
                                    loopIterationSelector.listAttr = edgeMenu.currentEdge.src.root
                                    loopIterationSelector.value = loopIterationSelector.listAttr ? loopIterationSelector.listAttr.value.indexOf(edgeMenu.currentEdge.src) + 1 : 0
                                }
                            }
                        }

                        // We add 1 to the index because of human readable index (starting at 1)
                        value: listAttr ? listAttr.value.indexOf(edgeMenu.currentEdge.src) + 1 : 0
                        range: { "min": 1, "max": listAttr ? listAttr.value.count : 0 }

                        onValueChanged: {
                            if (listAttr === null) {
                                return
                            }
                            const newSrcAttr = listAttr.value.at(value - 1)
                            const dst = edgeMenu.currentEdge.dst

                            // If the edge exists, do not replace it
                            if (newSrcAttr === edgeMenu.currentEdge.src && dst === edgeMenu.currentEdge.dst) {
                                return
                            }
                            edgeMenu.currentEdge = uigraph.replaceEdge(edgeMenu.currentEdge, newSrcAttr, dst)
                        }
                    }

                    MaterialToolButton {
                        font.pointSize: 13
                        ToolTip.text: GraphShortcuts.hint("Remove", "removeEdge") + "\n" + GraphShortcuts.hint("Cut", "cut")
                        enabled: edgeMenu.currentEdge && !edgeMenu.currentEdge.dst.node.locked && !edgeMenu.currentEdge.dst.isReadOnly
                        text: MaterialIcons.delete_
                        onClicked: {
                            uigraph.removeEdge(edgeMenu.currentEdge)
                            edgeMenu.close()
                        }
                    }

                    MaterialToolButton {
                        id: expandButton

                        property bool canExpand: edgeMenu.currentEdge && edgeMenu.forLoop

                        visible: edgeMenu.currentEdge && edgeMenu.forLoop && canExpand
                        enabled: edgeMenu.currentEdge && !edgeMenu.currentEdge.dst.node.locked && !edgeMenu.currentEdge.dst.isReadOnly
                        font.pointSize: 13
                        ToolTip.text: "Expand"
                        text: MaterialIcons.open_in_full

                        onClicked: {
                            edgeMenu.currentEdge = uigraph.expandForLoop(edgeMenu.currentEdge)
                            canExpand = false
                            edgeMenu.close()
                        }
                    }

                    MaterialToolButton {
                        id: collapseButton

                        visible: edgeMenu.currentEdge && edgeMenu.forLoop && !expandButton.canExpand
                        enabled: edgeMenu.currentEdge && !edgeMenu.currentEdge.dst.node.locked && !edgeMenu.currentEdge.dst.isReadOnly
                        font.pointSize: 13
                        ToolTip.text: "Collapse"
                        text: MaterialIcons.close_fullscreen

                        onClicked: {
                            uigraph.collapseForLoop(edgeMenu.currentEdge)
                            expandButton.canExpand = true
                            edgeMenu.close()
                        }
                    }
                }
            }

            // Edges
            Repeater {
                id: edgesRepeater

                // Delay edges loading after nodes (edges needs attribute pins to be created)
                model: nodeRepeater.loaded && root.graph ? root.graph.edges : undefined

                delegate: Edge {
                    function getAttributePin(attribute, attributeToDelegate, nodeItem, isSource) {
                        if (!attribute) {
                            return null
                        }

                        // Pins are hidden below the full level of detail: anchor on the node aggregated port
                        if (nodeItem && nodeItem.lod > 0) {
                            return isSource ? nodeItem.outputPort : nodeItem.inputPort
                        }

                        // Get the first visible parent of "attribute"
                        let dstAttributeDelegate = attributeToDelegate[attribute.uuid]                        

                        if (dstAttributeDelegate && dstAttributeDelegate.visible) {
                            return dstAttributeDelegate
                        }

                        if (!attribute || !attribute.root) {
                            return null
                        }

                        let groupAttributeDelegate = null
                        let groupAttribute = attribute

                        while (groupAttribute && (!groupAttributeDelegate ||
                               (groupAttributeDelegate && !groupAttributeDelegate.visible && groupAttribute && groupAttribute.root))) {
                            groupAttribute = groupAttribute ? groupAttribute.root : null

                            if (groupAttribute) {
                                groupAttributeDelegate = attributeToDelegate[groupAttribute.uuid]
                            }
                        }

                        if (groupAttributeDelegate && groupAttributeDelegate.visible) {
                            return groupAttributeDelegate
                        }

                        return dstAttributeDelegate
                    }

                    readonly property var srcNodeItem: root._nodeToDelegate.get(edge.src.node)
                    readonly property var dstNodeItem: root._nodeToDelegate.get(edge.dst.node)
                    property var src: {
                        return getAttributePin(edge.src, root._attributeToDelegate, srcNodeItem, true)
                        }
                    property var dst: {
                        return getAttributePin(edge.dst, root._attributeToDelegate, dstNodeItem, false)
                        }
                    property bool isValidEdge: src != null && dst != null
                    // Overview: replaced by the merged edges, but kept (hidden) for the edges cutting
                    visible: isValidEdge && src.visible && dst.visible && root.lod < 2

                    property var loopSource: edge.src && edge.src.root && edge.src.root.value ? edge.src.root : null
                    // Aggregated ports have no attribute: foreach edges are drawn as regular ones
                    property bool forLoop: src != null && dst != null &&
                                           !!src.attribute && !!dst.attribute &&
                                           loopSource != null &&
                                           src.attribute.type === "ListAttribute" &&
                                           dst.attribute.type != "ListAttribute"

                    property bool inFocus: containsMouse || (edgeMenu.opened && edgeMenu.currentEdge === edge)
                    // Whether the edge is connected to a hovered/selected node
                    readonly property bool incident: root.activeNodeNames.has(edge.src.node.name) || root.activeNodeNames.has(edge.dst.node.name)

                    edge: object
                    isForLoop: forLoop
                    loopSize: forLoop ? loopSource.value.count : 0

                    iteration: forLoop ? loopSource.value.indexOf(edge.src) : 0
                    cut: edgeSelectionLine.hitSet.has(index) && !root.isEdgeLocked(edge)
                    highlighted: !!root.insertPreview && root.insertPreview.edge === edge
                    color: cut ? GraphTheme.edgeCut : edge.dst === root.edgeAboutToBeRemoved ? Colors.red : GraphTheme.dataTypeColor(edge.src.dataType)
                    thickness: forLoop ? 5 : highlighted ? 4 : (inFocus || incident) ? 3 : 2
                    // Contextual dimming is suspended while an edge is being dragged
                    opacity: root.draggedAttribute || root.activeNodeNames.size === 0 || incident || highlighted ? 1.0 : 0.3
                    dataState: {
                        const srcStatus = edge.src.node.globalStatus
                        if (srcStatus === "SUCCESS" && edge.dst.node.globalStatus === "RUNNING")
                            return "flow"
                        if (srcStatus === "SUCCESS" || !edge.src.node.isComputableType)
                            return "produced"
                        return "notProduced"
                    }
                    // Hovered, or incident to the hovered/selected nodes: drawn above the nodes, not hidden under them
                    z: inFocus || incident ? 1 : 0
                    point1x: isValidEdge ? src.globalX + src.outputAnchorPos.x : 0
                    point1y: isValidEdge ? src.globalY + src.outputAnchorPos.y : 0
                    point2x: isValidEdge ? dst.globalX + dst.inputAnchorPos.x : 0
                    point2y: isValidEdge ? dst.globalY + dst.inputAnchorPos.y : 0
                    onPressed: function(event) {
                        const canEdit = !edge.dst.node.locked

                        if (event.button) {
                            if (canEdit && (event.modifiers & Qt.AltModifier)) {
                                uigraph.removeEdge(edge)
                            } else if (event.button == Qt.RightButton) {
                                edgeMenu.currentEdge = edge
                                edgeMenu.forLoop = forLoop
                                var spawnPosition = mouseArea.mapToItem(draggable, mouseArea.mouseX, mouseArea.mouseY)
                                edgeMenu.x = spawnPosition.x
                                edgeMenu.y = spawnPosition.y
                                edgeMenu.open()
                            }
                        }
                    }
                }
            }

            // Overview: one neutral edge per pair of connected nodes, thicker with the number of edges it merges
            Repeater {
                id: mergedEdgesRepeater
                model: root.lod === 2 && nodeRepeater.loaded ? uigraph.mergedEdges : 0

                // Plain shape, same curve as the Edges: no interaction in the overview
                delegate: Shape {
                    readonly property var srcItem: root._nodeToDelegate.get(modelData.src)
                    readonly property var dstItem: root._nodeToDelegate.get(modelData.dst)
                    readonly property bool isValidEdge: !!srcItem && !!dstItem
                    readonly property bool cut: root.knifeHits.pairs.has(modelData.src.name + ">" + modelData.dst.name)

                    visible: isValidEdge
                    vendorExtensionsEnabled: false

                    ShapePath {
                        id: mergedPath
                        startX: isValidEdge ? srcItem.outputPort.globalX + srcItem.outputPort.outputAnchorPos.x : 0
                        startY: isValidEdge ? srcItem.outputPort.globalY + srcItem.outputPort.outputAnchorPos.y : 0
                        fillColor: "transparent"
                        strokeColor: cut ? GraphTheme.edgeCut : GraphTheme.nodeTextSecondary
                        strokeStyle: cut ? ShapePath.DashLine : ShapePath.SolidLine
                        // Screen pixels
                        strokeWidth: Math.min(2 + modelData.count, 8) / draggable.scale
                        capStyle: ShapePath.RoundCap

                        PathCubic {
                            property real ctrlPtDist: Math.max(40, Math.abs(x - mergedPath.startX) * 0.5)
                            x: isValidEdge ? dstItem.inputPort.globalX + dstItem.inputPort.inputAnchorPos.x : 0
                            y: isValidEdge ? dstItem.inputPort.globalY + dstItem.inputPort.inputAnchorPos.y : 0
                            control1X: mergedPath.startX + ctrlPtDist
                            control1Y: mergedPath.startY
                            control2X: x - ctrlPtDist
                            control2Y: y
                        }
                    }
                }
            }

            Loader {
                id: nodeMenuLoader
                property var currentNode: null
                active: currentNode != null
                sourceComponent: nodeMenuComponent

                function load(node) {
                    currentNode = node
                }

                function unload() {
                    currentNode = null
                }

                function showDataDeletionDialog(deleteFollowing: bool, callback) {
                    uigraph.forceNodesStatusUpdate()
                    const dialog = deleteDataDialog.createObject(
                        root,
                        {
                            "node": currentNode,
                            "deleteFollowing": deleteFollowing
                        }
                    )
                    dialog.open()
                    if(callback)
                        dialog.dataDeleted.connect(callback)
                }
            }

            Component {
                id: nodeMenuComponent
                Menu {
                    id: nodeMenu

                    property var currentNode: nodeMenuLoader.currentNode

                    // Cache computatibility/submitability status of each selected node.
                    readonly property var nodeSubmitOrComputeStatus: {
                        var collectedStatus = ({})
                        uigraph.nodeSelection.selectedIndexes.forEach(function(idx) {
                            const node = uigraph.graph.nodes.at(idx.row)
                            collectedStatus[node] = uigraph.graph.canSubmitOrCompute(node)
                        })
                        return collectedStatus
                    }

                    readonly property bool isSelectionFullyComputed: {
                        return uigraph.nodeSelection.selectedIndexes.every(function(idx) {
                            const node = uigraph.graph.nodes.at(idx.row)
                            return node.isComputed
                        })
                    }

                    // Selection contains only compatibility nodes
                    readonly property bool isSelectionFullyCompatibility: {
                        return uigraph.nodeSelection.selectedIndexes.every(function(idx) {
                            const node = uigraph.graph.nodes.at(idx.row)
                            return node.isCompatibilityNode
                        })
                    }

                    // Selection contains at least one computable node type
                    readonly property bool selectionContainsComputableNodeType: {
                        return uigraph.nodeSelection.selectedIndexes.some(function(idx) {
                            const node = uigraph.graph.nodes.at(idx.row)
                            return node.isComputableType
                        })
                    }

                    readonly property bool canSelectionBeComputed: {
                        if(!selectionContainsComputableNodeType)
                            return false
                        if(isSelectionFullyCompatibility)
                            return false
                        if(isSelectionFullyComputed)
                            return true
                        var b = uigraph.nodeSelection.selectedIndexes.every(function(idx) {
                            const node = uigraph.graph.nodes.at(idx.row)
                            return (
                                node.isComputed ||
                                (uigraph.graph.canComputeTopologically(node) &&
                                // canCompute if canSubmitOrCompute == 1(can compute) or 3(can compute & submit)
                                nodeSubmitOrComputeStatus[node] % 2 == 1)
                            )
                        })
                        return b
                    }

                    readonly property bool isSelectionSubmitable: uigraph.canSubmit && selectionContainsComputableNodeType

                    readonly property bool canSelectionBeSubmitted: {
                        if(!selectionContainsComputableNodeType)
                            return false
                        if(isSelectionFullyCompatibility)
                            return false
                        if(isSelectionFullyComputed)
                            return true
                        return uigraph.nodeSelection.selectedIndexes.every(function(idx) {
                            const node = uigraph.graph.nodes.at(idx.row)
                            return (
                                node.isComputed ||
                                (uigraph.graph.canComputeTopologically(node) &&
                                 // canSubmit if canSubmitOrCompute == 2(can submit) or 3(can compute & submit)
                                 nodeSubmitOrComputeStatus[node] > 1)
                            )
                        })
                    }

                    width: 220

                    Component.onCompleted: popup()
                    onClosed: nodeMenuLoader.unload()

                    MenuItem {
                        id: computeMenuItem
                        text: nodeMenu.isSelectionFullyComputed ? "Re-Compute" : "Compute"
                        visible: nodeMenu.selectionContainsComputableNodeType
                        height: visible ? implicitHeight : 0
                        enabled: nodeMenu.canSelectionBeComputed

                        onTriggered: {
                            if (nodeMenu.isSelectionFullyComputed) {
                                nodeMenuLoader.showDataDeletionDialog(
                                    false,
                                    function(request, uigraph) {
                                        request(uigraph.getSelectedNodes())
                                    }.bind(null, computeRequest, uigraph)
                                )
                            } else {
                                computeRequest(uigraph.getSelectedNodes())
                            }
                        }
                    }
                    MenuItem {
                        id: submitMenuItem

                        text: nodeMenu.isSelectionFullyComputed ? "Re-Submit" : "Submit"
                        visible: nodeMenu.isSelectionSubmitable
                        height: visible ? implicitHeight : 0
                        enabled: nodeMenu.canSelectionBeSubmitted

                        onTriggered: {
                            if (nodeMenu.isSelectionFullyComputed) {
                                nodeMenuLoader.showDataDeletionDialog(
                                    false,
                                    function(request, uigraph) {
                                        request(uigraph.getSelectedNodes())
                                    }.bind(null, submitRequest, uigraph)
                                )
                            } else {
                                submitRequest(uigraph.getSelectedNodes())
                            }
                        }
                    }
                    MenuItem {
                        text: "Stop Computation"
                        enabled: nodeMenu.currentNode.canBeStopped() && nodeMenu.currentNode.globalExecMode == "LOCAL"
                        visible: enabled
                        height: visible ? implicitHeight : 0
                        onTriggered: uigraph.stopNodeComputation(nodeMenu.currentNode)
                    }
                    MenuItem {
                        text: "Cancel Computation"
                        enabled: nodeMenu.currentNode.canBeCanceled() && nodeMenu.currentNode.globalExecMode == "LOCAL"
                        visible: enabled
                        height: visible ? implicitHeight : 0
                        onTriggered: uigraph.cancelNodeComputation(nodeMenu.currentNode)
                    }
                    MenuItem {
                        text: "Interrupt Job"
                        enabled: nodeMenu.currentNode.canBeStopped() && nodeMenu.currentNode.globalExecMode == "EXTERN"
                        visible: enabled
                        height: visible ? implicitHeight : 0
                        onTriggered: uigraph.stopNode(nodeMenu.currentNode)
                    }
                    MenuItem {
                        text: "Cancel Job"
                        enabled: nodeMenu.currentNode.canBeCanceled() && nodeMenu.currentNode.globalExecMode == "EXTERN"
                        visible: enabled
                        height: visible ? implicitHeight : 0
                        onTriggered: uigraph.stopNode(nodeMenu.currentNode)
                    }
                    MenuItem {
                        text: "Retry Error Tasks"
                        enabled: nodeMenu.currentNode.globalExecMode == "EXTERN" && ["ERROR", "STOPPED", "KILLED"].includes(nodeMenu.currentNode.globalStatus)
                        visible: enabled
                        height: visible ? implicitHeight : 0
                        onTriggered: uigraph.restartJobErrorTasks(nodeMenu.currentNode)
                    }
                    MenuItem {
                        text: "Open Folder"
                        visible: nodeMenu.currentNode.isComputableType
                        height: visible ? implicitHeight : 0
                        onTriggered: Qt.openUrlExternally(Filepath.stringToUrl(nodeMenu.currentNode.internalFolder))
                    }
                    MenuSeparator {
                        visible: nodeMenu.currentNode.isComputableType
                    }
                    MenuItem {
                        text: "Cut Node(s)"
                        enabled: true
                        ToolTip.text: "Copy selection to the clipboard and remove it"
                        ToolTip.visible: hovered
                        onTriggered: {
                            copyNodes()
                            uigraph.removeSelectedNodes()
                        }
                    }
                    MenuItem {
                        text: "Copy Node(s)"
                        enabled: true
                        ToolTip.text: "Copy selection to the clipboard"
                        ToolTip.visible: hovered
                        onTriggered: copyNodes()
                    }
                    MenuItem {
                        text: "Paste Node(s)"
                        enabled: true
                        ToolTip.text: "Copy selection to the clipboard and immediately paste it"
                        ToolTip.visible: hovered
                        onTriggered: {
                            copyNodes()
                            pasteNodes()
                        }
                    }
                    MenuItem {
                        text: "Disconnect Node(s)"
                        enabled: true
                        ToolTip.text: GraphShortcuts.hint("Disconnect all edges from the selected Node(s)", "disconnect")
                        ToolTip.visible: hovered
                        onTriggered: uigraph.disconnectSelectedNodes()
                    }
                    MenuItem {
                        text: "Duplicate Node(s)" + (duplicateFollowingButton.hovered ? " From Here" : "")
                        enabled: true
                        onTriggered: duplicateNode(false)
                        ToolTip.text: GraphShortcuts.hint("Duplicate", "duplicate")
                        ToolTip.visible: hovered && !duplicateFollowingButton.hovered
                        MaterialToolButton {
                            id: duplicateFollowingButton
                            height: parent.height
                            anchors {
                                right: parent.right
                                rightMargin: parent.padding
                            }
                            text: MaterialIcons.fast_forward
                            onClicked: {
                                duplicateNode(true)
                                nodeMenu.close()
                            }
                        }
                    }
                    MenuItem {
                        text: "Remove Node(s)" + (removeFollowingButton.hovered ? " From Here" : "")
                        enabled: !nodeMenu.currentNode.locked
                        onTriggered: uigraph.removeSelectedNodes()
                        ToolTip.text: GraphShortcuts.hint("Remove", "remove")
                        ToolTip.visible: hovered && !removeFollowingButton.hovered
                        MaterialToolButton {
                            id: removeFollowingButton
                            height: parent.height
                            anchors {
                                right: parent.right
                                rightMargin: parent.padding
                            }
                            text: MaterialIcons.fast_forward
                            onClicked: {
                                uigraph.removeNodesFrom(uigraph.getSelectedNodes())
                                nodeMenu.close()
                            }
                        }
                    }
                    MenuSeparator {
                        visible: nodeMenu.currentNode.isComputableType
                    }
                    MenuItem {
                        id: deleteDataMenuItem
                        text: "Delete Data" + (deleteFollowingButton.hovered ? " From Here" : "" ) + "..."
                        visible: nodeMenu.currentNode.isComputableType
                        height: visible ? implicitHeight : 0
                        enabled: {
                            if (!nodeMenu.currentNode)
                                return false
                            // Check if the current node is locked (needed because it does not belong to its own duplicates list)
                            if (nodeMenu.currentNode.locked)
                                return false
                            // Check if at least one of the duplicate nodes is locked
                            for (let i = 0; i < nodeMenu.currentNode.duplicates.count; ++i) {
                                if (nodeMenu.currentNode.duplicates.at(i).locked)
                                    return false
                            }
                            return true
                        }

                        onTriggered: nodeMenuLoader.showDataDeletionDialog(false)

                        MaterialToolButton {
                            id: deleteFollowingButton
                            anchors {
                                right: parent.right
                                rightMargin: parent.padding
                            }
                            height: parent.height
                            text: MaterialIcons.fast_forward
                            onClicked: {
                                nodeMenuLoader.showDataDeletionDialog(true)
                                nodeMenu.close()
                            }
                        }
                    }
                }
            }

            // Confirmation dialog for node cache deletion
            Component {
                id: deleteDataDialog
                MessageDialog  {
                    property var node
                    property bool deleteFollowing: false

                    signal dataDeleted()

                    focus: true
                    modal: false
                    header.visible: false

                    text: "Delete Data of '" + node.label + "'" + (uigraph.nodeSelection.selectedIndexes.length > 1 ? " and other selected Nodes" : "") + (deleteFollowing ?  " and following Nodes?" : "?")
                    helperText: "Warning: This operation cannot be undone."
                    standardButtons: Dialog.Yes | Dialog.Cancel

                    onAccepted: {
                        if (deleteFollowing)
                            uigraph.clearDataFrom(uigraph.getSelectedNodes())
                        else
                            uigraph.clearSelectedNodesData()
                        dataDeleted()
                    }
                    onClosed: destroy()
                }
            }

            // Nodes
            Repeater {
                id: nodeRepeater

                model: root.graph ? root.graph.nodes : undefined

                property bool loaded: model ? count === model.count : false
                property bool ongoingDrag: false
                property bool updateSelectionOnClick: false
                property var temporaryEdgeAboutToBeRemoved: undefined
                // Modifiers of the last node press/release: Alt at the drop prevents the insertion on an edge
                property int dropModifiers: Qt.NoModifier

                function getItemAt(index) {
                    const loader = itemAt(index)
                    if (loader && loader.item)
                        return loader.item
                    return null
                }

                delegate: Loader {
                    id: nodeLoader
                    Component {
                        id: nodeComponent
                        Node {
                            id: nodeDelegate

                            node: object
                            width: uigraph.layout.nodeWidth
                            footprintHeight: uigraph.layout.nodeHeight
                            lod: root.lod
                            zoom: draggable.scale

                            Component.onCompleted: root.registerNodeDelegate(node, nodeDelegate)
                            Component.onDestruction: root.unregisterNodeDelegate(nodeDelegate)
                            onZoomRequested: root.zoomToNode(nodeDelegate)

                            mainSelected: uigraph.selectedNode === node
                            hovered: uigraph.hoveredNode === node
                            hasWarnings: node.hasInvalidAttribute

                            // ItemSelectionModel.hasSelection triggers updates anytime the selectionChanged() signal is emitted.
                            selected: uigraph.nodeSelection.hasSelection ? uigraph.nodeSelection.isRowSelected(index) : false

                            onAttributePinCreated: function(attribute, pin) { registerAttributePin(attribute, pin) }
                            onAttributePinDeleted: function(attribute, pin) { unregisterAttributePin(attribute, pin) }

                            // Connection guide: dim the nodes without any compatible pin (except the dragged edge's node)
                            compatibleAttributeUuids: root.compatibleAttributeUuids
                            insertAttributeUuids: root.insertPreview ? root.insertPreview.uuids : null
                            opacity: root.compatibleNodeNames && !root.compatibleNodeNames.has(node.name) && root.draggedAttribute.node !== node ? 0.35 : 1.0
                            onConnectionDragChanged: function(attribute, connectorType, dragItem) { root.setConnectionDrag(attribute, connectorType, dragItem) }
                            onDropTargetChanged: function(attribute, reason) {
                                root.dropTargetAttribute = attribute
                                root.dropTargetReason = reason
                            }

                            onShaked: {
                                uigraph.disconnectSelectedNodes()
                            }

                            onPressed: function(mouse) {
                                nodeRepeater.updateSelectionOnClick = true
                                nodeRepeater.ongoingDrag = true
                                nodeRepeater.dropModifiers = mouse.modifiers

                                let selectionMode = ItemSelectionModel.NoUpdate

                                if (!selected) {
                                    selectionMode = ItemSelectionModel.ClearAndSelect
                                }

                                if (mouse.button === Qt.LeftButton) {
                                    if (mouse.modifiers & Qt.ShiftModifier) {
                                        selectionMode = ItemSelectionModel.Select
                                    }
                                    if (mouse.modifiers & Qt.ControlModifier) {
                                        selectionMode = ItemSelectionModel.Toggle
                                    }
                                    if (mouse.modifiers & Qt.AltModifier) {
                                        let selectFollowingMode = ItemSelectionModel.ClearAndSelect
                                        if (mouse.modifiers & Qt.ShiftModifier) {
                                            selectFollowingMode = ItemSelectionModel.Select
                                        }
                                        uigraph.selectFollowing(node, selectFollowingMode)
                                        // Indicate selection has been dealt with by setting conservative Select mode.
                                        selectionMode = ItemSelectionModel.Select
                                    }
                                }
                                else if (mouse.button === Qt.RightButton) {
                                    if (selected) {
                                        // Keep the full selection when right-clicking on an already selected node.
                                        nodeRepeater.updateSelectionOnClick = false
                                    }
                                }

                                if (selectionMode != ItemSelectionModel.NoUpdate) {
                                    nodeRepeater.updateSelectionOnClick = false
                                    uigraph.selectNodeByIndex(index, selectionMode)
                                }

                                // If the node is selected after this, make it the active selected node.
                                if (selected) {
                                    uigraph.selectedNode = node
                                }

                                // Open the node context menu once selection has been updated.
                                if (mouse.button == Qt.RightButton) {
                                    nodeMenuLoader.load(node)
                                }
                            }

                            onReleased: function(mouse, wasDragged) {
                                nodeRepeater.ongoingDrag = false
                                nodeRepeater.dropModifiers = mouse.modifiers
                            }

                            // Only called when the node has not been dragged.
                            onClicked: function(mouse) {
                                if (!nodeRepeater.updateSelectionOnClick) {
                                    return
                                }
                                uigraph.selectNodeByIndex(index)
                            }

                            onDoubleClicked: function(mouse) { root.nodeDoubleClicked(mouse, node) }

                            onEntered: uigraph.hoveredNode = node
                            onExited: uigraph.hoveredNode = null

                            onEdgeAboutToBeRemoved: function(input) {
                                /*
                                 * Sometimes the signals are not in the right order because of weird Qt/QML update order
                                 * (next DropArea entered signal before previous DropArea exited signal) so edgeAboutToBeRemoved
                                 * must be set to undefined before it can be set to another attribute object.
                                 */
                                if (input === undefined) {
                                    if (nodeRepeater.temporaryEdgeAboutToBeRemoved === undefined) {
                                        root.edgeAboutToBeRemoved = input
                                    } else {
                                        root.edgeAboutToBeRemoved = nodeRepeater.temporaryEdgeAboutToBeRemoved
                                        nodeRepeater.temporaryEdgeAboutToBeRemoved = undefined
                                    }
                                } else {
                                    if (root.edgeAboutToBeRemoved === undefined) {
                                        root.edgeAboutToBeRemoved = input
                                    } else {
                                        nodeRepeater.temporaryEdgeAboutToBeRemoved = input
                                    }
                                }
                            }

                            // Interactive dragging: move the visual delegates
                            onPositionChanged: {
                                if (!selected || !dragging) {
                                    return
                                }

                                // Check for shake on the node
                                checkForShake()
                                root.updateInsertCandidate(nodeDelegate)

                                // Compute offset between the delegate and the stored node position.
                                const offset = Qt.point(x - node.x, y - node.y)

                                uigraph.nodeSelection.selectedIndexes.forEach(function(idx) {
                                    if (idx != index) {
                                        const delegate = nodeRepeater.getItemAt(idx.row)
                                        delegate.x = delegate.node.x + offset.x
                                        delegate.y = delegate.node.y + offset.y
                                    }
                                })
                            }

                            // After drag: apply the final offset to all selected nodes
                            onMoved: function(position) {
                                const offset = Qt.point(position.x - node.x, position.y - node.y)
                                const insertion = root.insertPreview
                                root.clearInsertion()
                                // Drop on a previewed edge inserts the node, unless Alt is held
                                if (insertion && !(nodeRepeater.dropModifiers & Qt.AltModifier)) {
                                    uigraph.beginModification("Insert " + node.label + " on Edge")
                                    uigraph.moveSelectedNodesBy(offset)
                                    uigraph.insertNodeOnEdge(node, insertion.edge)
                                    uigraph.endModification()
                                } else {
                                    uigraph.moveSelectedNodesBy(offset)
                                }
                            }

                            Behavior on x {
                                enabled: !nodeRepeater.ongoingDrag
                                NumberAnimation { duration: 100 }
                            }
                            Behavior on y {
                                enabled: !nodeRepeater.ongoingDrag
                                NumberAnimation { duration: 100 }
                            }
                        }
                    }

                    Component {
                        id: backdropComponent
                        Backdrop {
                            id: backdropDelegate
                            node: object
                            modelInstantiator: nodeRepeater
                            zoom: draggable.scale

                            mainSelected: uigraph.selectedNode === node
                            hovered: uigraph.hoveredNode === node

                            // ItemSelectionModel.hasSelection triggers updates anytime the selectionChanged() signal is emitted.
                            selected: uigraph.nodeSelection.hasSelection ? uigraph.nodeSelection.isRowSelected(index) : false

                            onPressed: function(mouse) {
                                nodeRepeater.updateSelectionOnClick = true
                                nodeRepeater.ongoingDrag = true

                                ctrlHeld = (mouse.modifiers & Qt.ControlModifier) !== 0

                                let selectionMode = ItemSelectionModel.NoUpdate

                                if (!selected) {
                                    selectionMode = ItemSelectionModel.ClearAndSelect
                                }

                                if (mouse.button === Qt.LeftButton) {
                                    if (mouse.modifiers & Qt.ShiftModifier) {
                                        selectionMode = ItemSelectionModel.Select
                                    }
                                    if (mouse.modifiers & Qt.ControlModifier) {
                                        selectionMode = ItemSelectionModel.Clear
                                    }
                                    if (mouse.modifiers & Qt.AltModifier) {
                                        let selectFollowingMode = ItemSelectionModel.ClearAndSelect
                                        if (mouse.modifiers & Qt.ShiftModifier) {
                                            selectFollowingMode = ItemSelectionModel.Select
                                        }
                                        uigraph.selectFollowing(node, selectFollowingMode)
                                        // Indicate selection has been dealt with by setting conservative Select mode.
                                        selectionMode = ItemSelectionModel.Select
                                    }
                                } else if (mouse.button === Qt.RightButton) {
                                    if (selected) {
                                        // Keep the full selection when right-clicking on an already selected node.
                                        nodeRepeater.updateSelectionOnClick = false
                                    }
                                }

                                if (selectionMode != ItemSelectionModel.NoUpdate) {
                                    nodeRepeater.updateSelectionOnClick = false
                                    uigraph.selectNodeByIndex(index, selectionMode)
                                }

                                // If the node is selected after this, make it the active selected node.
                                if (selected) {
                                    uigraph.selectedNode = node
                                }

                                if (!(mouse.modifiers & Qt.AltModifier)) {
                                    uigraph.selectNodesByIndices(childrenIndices, ItemSelectionModel.Select)
                                }

                                // Open the node context menu once selection has been updated.
                                if (mouse.button == Qt.RightButton) {
                                    nodeMenuLoader.load(node)
                                }
                            }

                            onReleased: function(mouse, wasDragged) {
                                ctrlHeld = false
                                nodeRepeater.ongoingDrag = false
                            }

                            // Only called when the node has not been dragged.
                            onClicked: function(mouse) {
                                if (!nodeRepeater.updateSelectionOnClick) {
                                    return
                                }
                                uigraph.selectNodeByIndex(index)

                                if (!(mouse.modifiers & Qt.AltModifier)) {
                                    uigraph.selectNodesByIndices(childrenIndices, ItemSelectionModel.Select)
                                }
                            }

                            onDoubleClicked: function(mouse) { root.nodeDoubleClicked(mouse, node) }

                            onResized: function(width, height) {
                                uigraph.resizeNode(node, width, height)
                            }
                            onResizedAndMoved: function(width, height, position) {
                                uigraph.resizeAndMoveNode(node, width, height, position)
                            }

                            onEntered: uigraph.hoveredNode = node
                            onExited: uigraph.hoveredNode = null

                            // Interactive dragging: move the visual delegates
                            onPositionChanged: {
                                if (!selected || !dragging) {
                                    return
                                }

                                // Compute offset between the delegate and the stored node position.
                                const offset = Qt.point(x - node.x, y - node.y)

                                uigraph.nodeSelection.selectedIndexes.forEach(function(idx) {
                                    if (idx != index) {
                                        const delegate = nodeRepeater.getItemAt(idx.row)
                                        delegate.x = delegate.node.x + offset.x
                                        delegate.y = delegate.node.y + offset.y
                                    }
                                })
                            }

                            // After drag: apply the final offset to all selected nodes
                            onMoved: function(position) {
                                const offset = Qt.point(position.x - node.x, position.y - node.y)
                                uigraph.moveSelectedNodesBy(offset)
                            }

                            Behavior on x {
                                enabled: !nodeRepeater.ongoingDrag && !resizing && !uigraph.animationsDisabled
                                NumberAnimation { duration: 100 }
                            }
                            Behavior on y {
                                enabled: !nodeRepeater.ongoingDrag && !resizing && !uigraph.animationsDisabled
                                NumberAnimation { duration: 100 }
                            }
                        }
                    }

                    sourceComponent: object.isBackdropNode ? backdropComponent : nodeComponent

                    onLoaded: {
                        nodeLoader.z = Qt.binding(function() { return nodeLoader.item ? nodeLoader.item.z : 0 })
                    }
                }
            }
        }

        DelegateSelectionBox {
            id: nodeSelectionBox
            mouseArea: mouseArea
            modelInstantiator: nodeRepeater
            container: draggable
            onDelegateSelectionEnded: function(selectedIndices, modifiers) {
                let selectionMode = ItemSelectionModel.ClearAndSelect
                if(modifiers & Qt.ShiftModifier) {
                    selectionMode = ItemSelectionModel.Select
                } else if(modifiers & Qt.ControlModifier) {
                    selectionMode = ItemSelectionModel.Deselect
                }
                uigraph.selectNodesByIndices(selectedIndices, selectionMode)
            }
        }

        DelegateSelectionLine {
            id: edgeSelectionLine
            mouseArea: mouseArea
            modelInstantiator: edgesRepeater
            container: draggable
            onDelegateSelectionEnded: function(selectedIndices, modifiers) {
                uigraph.deleteEdgesByIndices(selectedIndices)
            }
        }

        // Knife counters, next to the cursor
        Rectangle {
            visible: edgeSelectionLine.active
            x: edgeSelectionLine.p2.x + 14
            y: edgeSelectionLine.p2.y + 14
            width: knifeLabel.implicitWidth + 12
            height: knifeLabel.implicitHeight + 6
            radius: 3
            color: activePalette.window
            border.color: GraphTheme.edgeCut

            Label {
                id: knifeLabel
                anchors.centerIn: parent
                font.family: GraphTheme.monoFamily
                font.pointSize: 8
                color: GraphTheme.edgeCut
                text: "\u2702 " + root.knifeHits.count + (root.knifeHits.locked > 0 ? " \u00B7 " + root.knifeHits.locked + " locked" : "")
            }
        }

        // Info about the edge being dragged, following its tip
        Rectangle {
            id: connectionDragInfo
            visible: root.draggedItem !== null

            readonly property point tip: {
                if (!root.draggedItem)
                    return Qt.point(0, 0)
                // mapToItem() is not reactive: depend explicitly on the dragged item position
                root.draggedItem.x + root.draggedItem.y
                return root.draggedItem.mapToItem(parent, root.draggedItem.width / 2, root.draggedItem.height / 2)
            }
            readonly property bool onTarget: root.dropTargetAttribute !== null

            x: tip.x + 14
            y: tip.y + 14
            width: dragInfoLabel.implicitWidth + 12
            height: dragInfoLabel.implicitHeight + 6
            radius: 3
            color: activePalette.window
            border.color: activePalette.mid

            Label {
                id: dragInfoLabel
                anchors.centerIn: parent
                font.family: GraphTheme.monoFamily
                font.pointSize: 8
                color: !connectionDragInfo.onTarget ? activePalette.text : root.dropTargetReason ? Colors.red : Colors.green
                text: {
                    if (!root.draggedAttribute)
                        return ""
                    if (!connectionDragInfo.onTarget)
                        return root.draggedAttribute.label + " \u00B7 " + root.draggedAttribute.dataType
                    if (root.dropTargetReason)
                        return "\u2715 " + root.dropTargetReason
                    return root.draggedAttribute.dataType + " \u2192 " + root.dropTargetAttribute.dataType + " \u2713"
                }
            }
        }

        DropArea {
            id: dropArea
            anchors.fill: parent
            keys: ["text/uri-list"]

            /// The InputNode delegate currently being hovered during a file drag, if any
            property var hoveredInputNodeDelegate: null

            onEntered: function(drag) {
                nbMeshroomScenes = 0
                nbDraggedFiles = drag.urls.length

                drag.urls.forEach(function(file) {
                    const extension = Filepath.extension(file)
                    if (extension === ".mg" || extension === ".mgt") {
                        nbMeshroomScenes++
                    }
                })

                // Check if the drag enters directly over an InputNode
                var draggablePos = mapToItem(draggable, drag.x, drag.y)
                hoveredInputNodeDelegate = inputNodeDelegateAt(draggablePos.x, draggablePos.y)
                if (hoveredInputNodeDelegate) {
                    hoveredInputNodeDelegate.inputNodeDragHover = true
                }
            }

            onPositionChanged: function(drag) {
                // Update which InputNode (if any) the drag is currently over
                var draggablePos = mapToItem(draggable, drag.x, drag.y)
                var newDelegate = inputNodeDelegateAt(draggablePos.x, draggablePos.y)
                if (newDelegate !== hoveredInputNodeDelegate) {
                    if (hoveredInputNodeDelegate) {
                        hoveredInputNodeDelegate.inputNodeDragHover = false
                    }
                    hoveredInputNodeDelegate = newDelegate
                    if (hoveredInputNodeDelegate) {
                        hoveredInputNodeDelegate.inputNodeDragHover = true
                    }
                }
            }

            onExited: {
                if (hoveredInputNodeDelegate) {
                    hoveredInputNodeDelegate.inputNodeDragHover = false
                    hoveredInputNodeDelegate = null
                }
            }

            onDropped: function(drop) {
                // Clear visual feedback
                if (hoveredInputNodeDelegate) {
                    hoveredInputNodeDelegate.inputNodeDragHover = false
                }

                // If dropped on an InputNode, forward the files to its initialize() method
                if (hoveredInputNodeDelegate) {
                    _currentScene.initializeNode(hoveredInputNodeDelegate.node, drop.urls)
                    hoveredInputNodeDelegate = null
                    return
                }

                if (nbMeshroomScenes == nbDraggedFiles || nbMeshroomScenes == 0) {
                    // Retrieve mouse position and convert coordinate system
                    // from pixel values to graph reference system
                    var mousePosition = mapToItem(draggable, drag.x, drag.y)
                    // Send the list of files,
                    // to create the corresponding nodes or open another scene
                    filesDropped(drop, mousePosition)
                } else {
                    errorDialog.open()
                }
            }
        }
    }

    NodeActions {
        id: nodeActions
        uigraph: root.uigraph
        draggable: draggable
        nodeRepeater: nodeRepeater
        nodeToDelegate: root._nodeToDelegate
        visible: root.lod < 2
        anchors.fill: parent

        onComputeRequest: function(node) {
            root.computeRequest([node])
        }

        onStopComputeRequest: function(node) {
            if (node.canBeStopped()) {
                uigraph.stopNodeComputation(node)
            } else if (node.canBeCanceled()) {
                uigraph.cancelNodeComputation(node)
            }
        }

        onDeleteDataRequest: function(node) {
            if (nodeActionsSettings.confirmBeforeDelete) {
                uigraph.forceNodesStatusUpdate();
                const dialog = deleteDataDialog.createObject(
                    root,
                    {
                        "node": node,
                        "deleteFollowing": false
                    }
                );
                dialog.open()
            }
            else {
                uigraph.clearSelectedNodesData()
            }
        }

        onSubmitRequest: function(node) {
            root.submitRequest([node])
        }

        onStopSubmitRequest: function(node) {
            if (node.canBeStopped() || node.canBeCanceled()) {
                uigraph.stopNode(node)
            }
        }

        onRetrySubmitRequest: function(node) {
            uigraph.restartJobErrorTasks(node)
        }
    }

    MessageDialog {
        id: errorDialog

        icon.text: MaterialIcons.error
        icon.color: "#F44336"

        title: "Different File Types"
        text: "Do not mix Meshroom project/template files and other types of files."
        standardButtons: Dialog.Ok

        parent: Overlay.overlay

        onAccepted: close()
    }

    // Zoom controls
    FloatingPane {
        id: zoomControls
        padding: 2
        anchors.bottom: parent.bottom
        RowLayout {
            spacing: 2
            MaterialToolButton {
                text: MaterialIcons.remove
                ToolTip.text: "Zoom Out — " + GraphShortcuts.keys("zoom")
                onClicked: root.zoomAt(root.width / 2, root.height / 2, 1 / mouseArea.factor)
            }
            // Click: 100 % on the center of the view
            ToolButton {
                text: Math.round(draggable.scale * 100) + " %"
                font.family: GraphTheme.monoFamily
                font.pointSize: 8
                padding: 2
                Layout.preferredWidth: 44
                ToolTip.visible: hovered
                ToolTip.text: "Zoom 100 %"
                onClicked: root.runAction("zoomReset")
            }
            MaterialToolButton {
                text: MaterialIcons.add
                ToolTip.text: "Zoom In — " + GraphShortcuts.keys("zoom")
                onClicked: root.zoomAt(root.width / 2, root.height / 2, mouseArea.factor)
            }
            // Separator
            Rectangle {
                Layout.fillHeight: true
                Layout.margins: 2
                implicitWidth: 1
                color: activePalette.window
            }
            MaterialToolButton {
                text: MaterialIcons.fullscreen
                ToolTip.text: GraphShortcuts.hint("Fit", "fit")
                onClicked: root.fit()
            }
            MaterialToolButton {
                text: MaterialIcons.linear_scale
                ToolTip.text: "Auto-Layout"
                onClicked: uigraph.layout.reset()
            }
        }
    }

    GraphMinimap {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 8
        width: 160
        height: 100
        visible: GraphEditorSettings.showMinimap && root.graph !== null && root.graph.nodes.count > 0 && !graphInView
        uigraph: root.uigraph
        draggable: draggable
        viewWidth: root.width
        viewHeight: root.height
        onCenterRequested: function(graphPoint) { root.centerOn(graphPoint) }
        onZoomRequested: function(graphPoint, factor) {
            const viewPoint = draggable.mapToItem(root, graphPoint.x, graphPoint.y)
            root.zoomAt(viewPoint.x, viewPoint.y, factor)
        }
    }

    CommandPalette {
        id: commandPalette
        property point spawnPosition
        x: Math.round((root.width - width) / 2)
        y: 12
        nodeTypes: root.nodeTypesModel || {}
        pipelines: MeshroomApp.pipelineTemplateNames
        graphNodes: root.graph ? root.graph.nodes : null
        onClosed: root.forceActiveFocus()
        onNodeTypeChosen: function(nodeType) { root.createNode(nodeType, spawnPosition) }
        onPipelineChosen: function(name) { root.importPipeline(name, spawnPosition) }
        onGraphNodeChosen: function(node) {
            uigraph.selectedNode = node
            uigraph.selectNodes([node])
            root.fitNode(root.nodeDelegate(node))
        }
        onCommandChosen: function(action) { root.runAction(action) }
    }

    // Toolbar
    FloatingPane {
        padding: 2
        anchors.bottom: parent.bottom
        anchors.left: zoomControls.right
        anchors.leftMargin: 4
        RowLayout {
            id: navigation
            spacing: 4

            // Default index for search
            property int currentIndex: -1
            // Add Backdrop
            MaterialToolButton {
                text: MaterialIcons.sticky_note_2
                ToolTip.text: "Add Backdrop"
                onClicked: root.addBackdrop()
            }

            // Separator
            Rectangle {
                Layout.fillHeight: true
                Layout.margins: 2
                implicitWidth: 1
                color: activePalette.window
            }

            ColorSelector {
                id: colorSelector
                Layout.minimumWidth: colorSelector.width

                // When a Color is selected
                onColorSelected: (color)=> {
                    uigraph.setSelectedNodesColor(color)
                }
            }

            // Separator
            Rectangle {
                Layout.fillHeight: true
                Layout.margins: 2
                implicitWidth: 1
                color: activePalette.window
            }

            // Search nodes in the graph
            SearchBar {
                id: graphSearchBar

                toggle: true // enable toggling the actual text field by the search button
                Layout.minimumWidth: graphSearchBar.width
                maxWidth: 150

                textField.background.opacity: 0.5
                textField.onTextChanged: navigation.currentIndex = -1

                onAccepted: {
                    navigation.navigateForward()
                }
            }

            MaterialToolButton {
                text: MaterialIcons.arrow_left
                padding: 0
                visible: graphSearchBar.text !== ""
                onClicked: navigation.navigateBackward()
            }

            MaterialToolButton {
                id: nextArrow
                text: MaterialIcons.arrow_right
                padding: 0
                visible: graphSearchBar.text !== ""
                onClicked: navigation.navigateForward()
            }

            Label {
                id: currentSearchLabel
                text: " " + (navigation.currentIndex + 1) + "/" + filteredNodes.count
                padding: 0
                visible: graphSearchBar.text !== ""
            }

            Repeater {
                id: filteredNodes
                model: SortFilterDelegateModel {
                    model: root.graph ? root.graph.nodes : undefined
                    sortRole: "label"
                    filters: [{role: "label", value: graphSearchBar.text}]
                    delegate: Item {
                        visible: false  // Hide the items to not affect the layout as the nodes model gets changes
                        property var index_: index
                    }
                    function modelData(item, roleName_) {
                        return item.model.object[roleName_]
                    }
                }
            }

            function navigateForward() {
                /**
                 * Moves the navigation index forwards and focuses on the next node as per index.
                 */
                if (!filteredNodes.count)
                    return

                navigation.currentIndex++
                if (navigation.currentIndex === filteredNodes.count)
                    navigation.currentIndex = 0
                navigation.nextItem()
            }

            function navigateBackward() {
                /**
                 * Moves the navigation index backwards and focuses on the previous node as per index.
                 */
                if (!filteredNodes.count)
                    return

                navigation.currentIndex--
                if (navigation.currentIndex === -1)
                    navigation.currentIndex = filteredNodes.count - 1
                navigation.nextItem()
            }

            function nextItem() {
                root.fitNode(nodeRepeater.getItemAt(filteredNodes.itemAt(navigation.currentIndex).index_))
            }
        }
    }

    // Pins are created and destroyed by whole nodes (level of detail changes): notify the edges once for all of them
    function notifyAttributeToDelegateChanged() {
        root._attributeToDelegateChanged()
    }

    function registerAttributePin(attribute, pin) {
        root._attributeToDelegate[attribute.uuid] = pin
        Qt.callLater(root.notifyAttributeToDelegateChanged)
    }

    function unregisterAttributePin(attribute, pin) {
        if (!attribute || !Object.prototype.hasOwnProperty.call(attribute, 'uid')) { return }

        if (attribute.uuid in root._attributeToDelegate) {
            if (root._attributeToDelegate[attribute.uuid] !== pin) { return }
            delete root._attributeToDelegate[attribute.uuid]
            Qt.callLater(root.notifyAttributeToDelegateChanged)
        }
    }

    function registerNodeDelegate(node, delegate) {
        root._nodeToDelegate.set(node, delegate)
        root._nodeToDelegateChanged()
    }

    function unregisterNodeDelegate(delegate) {
        // The node may already be destroyed: look the delegate up
        for (const [node, item] of root._nodeToDelegate) {
            if (item === delegate) {
                root._nodeToDelegate.delete(node)
                root._nodeToDelegateChanged()
                return
            }
        }
    }

    function boundingBox() {
        var first = nodeRepeater.getItemAt(0)
        if (first === null) {
            return Qt.rect(0, 0, 0, 0)
        }
        var firstRect = footprint(first)
        var bbox = Qt.rect(firstRect.x, firstRect.y, firstRect.x + firstRect.width, firstRect.y + firstRect.height)
        for (var i = 0; i < root.graph.nodes.count; ++i) {
            var item = footprint(nodeRepeater.getItemAt(i))
            bbox.x = Math.min(bbox.x, item.x)
            bbox.y = Math.min(bbox.y, item.y)
            bbox.width = Math.max(bbox.width, item.x + item.width)
            bbox.height = Math.max(bbox.height, item.y + item.height)
        }
        bbox.width -= bbox.x
        bbox.height -= bbox.y
        return bbox
    }

    function selectionBoundingBox() {
        /**
         * Returns the bounding box considering the nodes which are selected.
         * The returned bounding box starts from the Minumum x,y position to the
         * Maximum x,y postion of the selected nodes.
         */
        var firstIdx = uigraph.nodeSelection.selectedIndexes[0]
        const first = footprint(nodeRepeater.getItemAt(firstIdx.row))
        // Bounding box of the first selected item
        var bbox = Qt.rect(first.x, first.y, first.x + first.width, first.y + first.height)
        // Iterate over the remaining items in the selection
        uigraph.nodeSelection.selectedIndexes.forEach(function(idx) {
            if(idx != firstIdx) {
                const item = footprint(nodeRepeater.getItemAt(idx.row))
                bbox.x = Math.min(bbox.x, item.x)
                bbox.y = Math.min(bbox.y, item.y)
                bbox.width = Math.max(bbox.width, item.x + item.width)
                bbox.height = Math.max(bbox.height, item.y + item.height)
            }
        })

        bbox.width -= bbox.x
        bbox.height -= bbox.y
        return bbox
    }

    // Fit graph to fill root
    function fit() {
        var bbox
        // Compute bounding box
        if (uigraph.nodeSelection.hasSelection) {
            bbox = selectionBoundingBox()
        }
        else {
            bbox = boundingBox()
        }
        // Rescale to fit the bounding box in the view, zoom is limited to prevent huge text
        draggable.scale = Math.min(Math.min(root.width / bbox.width, root.height / bbox.height), maxZoom)
        // Recenter
        draggable.x = bbox.x * draggable.scale * -1 + (root.width - bbox.width * draggable.scale) * 0.5
        draggable.y = bbox.y * draggable.scale * -1 + (root.height - bbox.height * draggable.scale) * 0.5
    }
}
