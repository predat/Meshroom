import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects

import MaterialIcons 2.2
import Utils 1.0

/**
 * Visual representation of a Graph Node.
 */

Item {
    id: root

    /// The underlying Node object
    property variant node
    /// Whether the node can be modified
    property bool readOnly: node.locked
    /// Whether the node is in compatibility mode
    readonly property bool isCompatibilityNode: node ? node.hasOwnProperty("compatibilityIssue") : false
    /// Mouse related states
    property bool mainSelected: false
    property bool selected: false
    property bool hovered: false
    property bool dragging: mouseArea.drag.active
    /// Node label
    property string nodeLabel: node ? node.label : ""
    /// Combined x and y
    property point position: Qt.point(x, y)
    /// Uuids of the attributes an edge being dragged can be connected to (null when no edge is dragged)
    property var compatibleAttributeUuids: null
    /// Uuids of the attributes of a previewed node insertion on an edge (null otherwise)
    property var insertAttributeUuids: null
    /// Level of detail: 0 = full, 1 = structure (header and chunks, aggregated ports), 2 = overview (pill)
    property int lod: 0
    /// Graph zoom: the overview pill keeps a constant size on screen
    property real zoom: 1.0
    /// Height used for the selection and the framing: the visible height depends on the level of detail
    property real footprintHeight: height
    /// Ports on which the edges converge below the full level of detail
    readonly property alias inputPort: inputPortItem
    readonly property alias outputPort: outputPortItem
    /// Vertical extent of the attribute pins, relative to the node
    readonly property real attributesTop: nodeAttributes.y + attributesColumn.topPadding
    readonly property real attributesBottom: nodeAttributes.y + attributesColumn.height - attributesColumn.bottomPadding
    /// Vertical extent of the gap between the output and the input attributes (-1 when there is none)
    readonly property real attributesGapTop: attributesGap.visible ? nodeAttributes.y + attributesGap.y : -1
    readonly property real attributesGapBottom: attributesGap.visible ? attributesGapTop + attributesGap.height : -1

    /// Icon tile: always the hue of the node type category (the user color only goes to the header strip)
    readonly property var categoryStyle: Colors.categoryStyle(node && _nodeTypes[node.nodeType] ? _nodeTypes[node.nodeType].category : "")
    readonly property color tileTint: Colors.tokenColor(categoryStyle.color)

    /// Finished chunks, total chunks and the sum of the finished chunks durations
    readonly property var chunkStats: {
        let done = 0
        let elapsed = 0
        const chunks = node && node.chunksCreated ? node.chunks : null
        const count = chunks ? chunks.count : 0
        for (let i = 0; i < count; ++i) {
            const chunk = chunks.at(i)
            if (chunk.statusName === "SUCCESS") {
                done++
                elapsed += chunk.elapsedTime
            }
        }
        return { "done": done, "count": count, "elapsed": elapsed }
    }

    /// Status chip: { icon, text, color }, null for nodes which are not computed or not started (NONE)
    readonly property var statusChip: {
        if (!node || !node.isComputableType)
            return null
        const status = node.globalStatus
        const colors = Colors.nodeStatusColors
        switch (status) {
        case "SUBMITTED":
            if (node.isExternal)
                return { "icon": MaterialIcons.cloud_upload, "text": "Submitted", "color": Colors.nodeStatusFarm }
            return { "icon": MaterialIcons.schedule, "text": "Queued", "color": colors["SUBMITTED"] }
        case "RUNNING": {
            const percent = chunkStats.count > 0 ? Math.round(100 * chunkStats.done / chunkStats.count) : 0
            return { "icon": node.isExternal ? MaterialIcons.cloud : MaterialIcons.play_circle, "text": percent + " %",
                     "color": node.isExternal ? Colors.nodeStatusFarm : colors["RUNNING"] }
        }
        case "SUCCESS": return { "icon": MaterialIcons.check, "text": "Done", "color": colors["SUCCESS"] }
        case "ERROR": return { "icon": MaterialIcons.close, "text": "Error", "color": colors["ERROR"] }
        case "STOPPED": return { "icon": MaterialIcons.stop_circle, "text": "Stopped", "color": colors["STOPPED"] }
        case "KILLED": return { "icon": MaterialIcons.cancel, "text": "Killed", "color": colors["KILLED"] }
        }
        return null
    }

    /// Whether an attribute, or one of the children of a group, is connected: its pin is shown even with the params collapsed
    function isConnected(attribute) {
        if (attribute.hasAnyInputLinks || attribute.hasAnyOutputLinks)
            return true
        return attribute.type === "GroupAttribute" && attribute.flatStaticChildren.some(child => child.hasAnyInputLinks || child.hasAnyOutputLinks)
    }

    /// Number of hidden parameters (not exposed, not connected) which differ from their default value
    readonly property int modifiedParamsCount: {
        let count = 0
        for (let i = 0; node && i < node.attributes.count; ++i) {
            const attr = node.attributes.at(i)
            if (!attr.isOutput && !attr.exposed && attr.desc.visible && !isConnected(attr) && !attr.isDefault)
                count++
        }
        return count
    }

    function formatDuration(seconds) {
        /*
         * Formats a duration in seconds as "0.4 s", "12 s", "3:41" or "1:03:41".
         */
        if (seconds < 10)
            return seconds.toFixed(1) + " s"
        if (seconds < 60)
            return Math.round(seconds) + " s"
        const s = Math.round(seconds)
        const pad = (v) => (v < 10 ? "0" : "") + v
        if (s < 3600)
            return Math.floor(s / 60) + ":" + pad(s % 60)
        return Math.floor(s / 3600) + ":" + pad(Math.floor(s / 60) % 60) + ":" + pad(s % 60)
    }

    function shortLabel(label) {
        /*
         * Abbreviates each long word of a camel case label to its first syllable, for the overview pill:
         * "CameraInit" -> "CamInit", "FeatureExtraction" -> "FeatExtr". Short words, acronyms and numbers are kept.
         */
        return label.replace(/[A-Z]?[a-z]+/g, function(word) {
            if (word.length <= 4)
                return word
            const syllable = word.match(/^[^aeiouy]*[aeiouy]+[^aeiouy]*/i)
            return syllable ? syllable[0].slice(0, 5) : word.slice(0, 4)
        })
    }

    function statusTooltip() {
        /*
         * Returns the status chip tooltip: the status word, plus the remaining time while running,
         * estimated from the mean duration of the finished chunks (omitted without finished chunks).
         */
        let str = statusChip.text + (node.isExternal ? " (external)" : "")
        const remaining = chunkStats.count - chunkStats.done
        if (node.globalStatus === "RUNNING" && chunkStats.done > 0 && remaining > 0)
            str += "<br>ETA ~" + formatDuration(chunkStats.elapsed / chunkStats.done * remaining)
        return str
    }

    /// Shake Relevance
    readonly property double maxAmplitude: 500.0;
    readonly property int shakeThreshold: 5;

    property int shakeCounter: 0;
    property bool shaking: false;
    property int shakeDetectionInterval: 1000;  // 1 Second to complete the shake else the counter is reset

    property double originalRootX: 0.0;
    property double originalRootY: 0.0;

    property int directionX: 0;
    property int directionY: 0;

    property point mousePosition: Qt.point(mouseArea.mouseX, mouseArea.mouseY)
    property bool hasWarnings: false

    Item {
        id: m
        property bool displayParams: false
    }

    // Mouse interaction related signals
    signal pressed(var mouse)
    signal released(var mouse)
    signal clicked(var mouse)
    signal doubleClicked(var mouse)
    signal moved(var position)
    signal shaked()
    signal entered()
    signal exited()

    // Already connected attribute with another edge in DropArea
    signal edgeAboutToBeRemoved(var input)
    /// An aggregated port has been dragged: the node should be zoomed in on to connect its attributes
    signal zoomRequested()

    /// Emitted when child attribute pins are created
    signal attributePinCreated(var attribute, var pin)
    /// Emitted when child attribute pins are deleted
    signal attributePinDeleted(var attribute, var pin)
    /// Relayed from the attribute pins: an edge started/stopped being dragged, the dragged edge entered/left a pin
    signal connectionDragChanged(var attribute, string connectorType, var dragItem)
    signal dropTargetChanged(var attribute, string reason)

    // use node name as object name to simplify debugging
    objectName: node ? node.name : ""

    // initialize position with node coordinates
    x: root.node ? root.node.x : undefined
    y: root.node ? root.node.y : undefined

    implicitHeight: childrenRect.height

    SystemPalette { id: activePalette }

    Connections {
        target: root.node
        // update x,y when node position changes
        function onPositionChanged() {
            root.x = root.node.x
            root.y = root.node.y
        }
        function onNameChanged() {
            // HACK: Make sure when the node name changes the node label is updated
            root.nodeLabel = ""
            // Restore binding to root.node.label
            root.nodeLabel = Qt.binding(function() { return root.node.label; })
        }
    }

    Timer {
        id: shakeDetectionTimer;
        interval: root.shakeDetectionInterval;
        onTriggered: {
            if (root.shaking) {
                root.resetShaking();
            }
        }
    }

    function beginShaking() {
        /**
         * Sets up the shake related values.
         * Enables Shake detection.
         */
        root.shaking = true;

        // Capture the current Root's X and Y to use in detecting the movement of the node around these points
        root.originalRootX = root.x;
        root.originalRootY = root.y;
    }

    function resetShaking() {
        /**
         * Resets the shaking and the variables tracking a shake.
         */
        // Reset the shake counter when shaking has ended
        root.shakeCounter = 0;

        // Reset the direction detection
        root.directionX = 0;
        root.directionY = 0;
    }

    function endShaking() {
        /**
         * Resets all values related to shaking.
         * Ends the shake detection.
         */
        root.shaking = false;

        root.resetShaking();
    }

    function checkForShake() {
        /**
         * Detects a shake if a the node has been moved across the originally captured x and y positions
         * back and forth a given number of times specified by the amplitude.
         */

        if (!root.shaking) {
            return;
        }

        // This indicates that the shake was either reset or we are starting from scratch
        if (root.shakeCounter === 0 && !shakeDetectionTimer.running) {
            shakeDetectionTimer.start();
        }

        const deltaX = root.x - root.originalRootX;
        const deltaY = root.y - root.originalRootY;

        // Check if the node has not travelled too much from the original position
        // If so, stop detecting a shake as that might not be needed
        if (Math.abs(deltaX) > root.maxAmplitude || Math.abs(deltaY) > root.maxAmplitude) {
            root.endShaking();
        }

        // This checks the current direction in which the node is travelling
        // if the node has moved on the left side of the original position -1
        // if the node has moved on the right side of the original position +1

        //        <--   Origin
        //       [Node]   |
        //                |   [Node]
        //                |     -->
        // If the motion continues to be like this 'threshold' number of times
        // This will be considered as a shake effect

        const currentDirectionX = deltaX > 0 ? 1 : -1;
        const currentDirectionY = deltaY > 0 ? 1 : -1;

        // Check if we are in the opposite direction of what was the previous direction of the Node
        // If yes then we are propagating as a shake effect
        if (currentDirectionX != root.directionX || currentDirectionY != root.directionY) {
            // One shake cycle is complete, increment the counter
            root.shakeCounter++;

            // Update the original direction to be the current one
            root.directionX = currentDirectionX;
            root.directionY = currentDirectionY;
        }

        // The node has moved in a shake effect to match the threshold and this is causing it to be detected as a shake
        if (root.shakeCounter > root.shakeThreshold) {
            root.shaked();
            // Reset the counter to detect another shake effect
            root.resetShaking();
        }
    }

    function formatInternalAttributesTooltip(invalidation, comment) {
        /*
         * Creates a string that contains the invalidation message (if it is not empty) in bold,
         * followed by the comment message (if it exists) in regular font, separated by an empty
         * line.
         * Invalidation and comment messages have their tabs or line returns in plain text format replaced
         * by their HTML equivalents.
         */
        let str = ""
        if (invalidation !== "") {
            let replacedInvalidation = node.invalidation.replace(/\n/g, "<br/>").replace(/\t/g, "&nbsp;&nbsp;&nbsp;&nbsp;")
            str += "<b>" + replacedInvalidation + "</b>"
        }
        if (invalidation !== "" && comment !== "") {
            str += "<br/><br/>"
        }
        if (comment !== "") {
            let replacedComment = node.comment.replace(/\n/g, "<br/>").replace(/\t/g, "&nbsp;&nbsp;&nbsp;&nbsp;")
            str += replacedComment
        }
        return str
    }

    // Used to generate list of node's label sharing the same uid
    function generateDuplicateList() {
        let str = "<b>Shares internal folder (data) with:</b>"
        for (let i = 0; i < node.duplicates.count; ++i) {
            if (i % 5 === 0)
                str += "<br>"

            const currentNode = node.duplicates.at(i)

            if (i === node.duplicates.count - 1) {
                str += currentNode.nameToLabel(currentNode.name)
                return str
            }

            str += (currentNode.nameToLabel(currentNode.name) + ", ")
        }
        return str
    }

    function updateChildPin(attribute, parentPins, pin) {
        /*
         * Update the pin of a child attribute: if the attribute is enabled and its parent is
         * a GroupAttribute, the visibility is determined based on the parent pin's "expanded" state,
         * using the "parentPins" map to access the status.
         * If the current pin is also a GroupAttribute and is expanded while its newly "visible" state
         * is false, it is reset.
         */
        const connected = isConnected(attribute)
        // A connected attribute keeps its pin, even disabled: its edges are anchored on it
        if (Boolean(attribute.enabled) || connected) {
            // If the parent is a GroupAttribute, use the status of the parent's pin to determine visibility
            // UNLESS the child attribute is already connected with a visible edge
            if (attribute.root && attribute.root.isExpandable) {

                var visible = Boolean(parentPins.get(attribute.root.fullName)) || connected
                if (!visible && parentPins.has(attribute.fullName) && parentPins.get(attribute.fullName) === true) {
                    parentPins.set(attribute.fullName, false)
                    attribute.expanded = false
                }
                return visible
            }
            return true
        }
        return false
    }

    function generateAttributesModel(isOutput, parentPins) {
        if (!node) {
            return undefined
        }

        const attributes = []
        for (let i = 0; i < node.attributes.count; i++) {
            let attr = node.attributes.at(i)
            if (attr.isOutput == isOutput) {
                // Add the attribute to the model
                attributes.push(attr)
                if (attr.isExpandable) {
                    // initialize its pin status
                    parentPins.set(attr.fullName, attr.expanded)
                }

                // Check and add any child this attribute might have
                attr.flatStaticChildren.forEach((child) =>
                    {
                        attributes.push(child)
                        if (child.isExpandable && !parentPins.has(child.fullName)) {
                            parentPins.set(child.fullName, child.expanded)
                        }
                    }
                )
            }
        }

        return attributes
    }

    // Main Layout
    MouseArea {
        id: mouseArea
        width: parent.width
        height: body.height
        drag.target: root
        // Small drag threshold to avoid moving the node by mistake
        drag.threshold: 2
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (mouse) => root.clicked(mouse)
        onDoubleClicked: (mouse) => root.doubleClicked(mouse)
        onEntered: root.entered()
        onExited: root.exited()
        drag.onActiveChanged: {
            if (!drag.active) {
                root.moved(Qt.point(root.x, root.y))
            }
        }

        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.ArrowCursor

        onPressed: function(mouse) {
            root.pressed(mouse);
            // Begin shake detection
            root.beginShaking();
        }

        onReleased: function(mouse) {
            root.released(mouse);
            // End shake detection
            root.endShaking();
        }

        // Selection halo (main selection only)
        Rectangle {
            anchors.fill: nodeContent
            anchors.margins: -6
            visible: root.mainSelected
            radius: background.radius + 6
            color: "transparent"
            border.width: 4
            border.color: ring.border.color
            opacity: 0.35
        }

        // Selection ring
        Rectangle {
            id: ring
            anchors.fill: nodeContent
            anchors.margins: -2
            visible: root.mainSelected || root.selected
            radius: background.radius + 2
            color: "transparent"
            // Constant on screen in the overview
            border.width: root.lod === 2 ? 2 / Math.max(root.zoom, 0.2) : 2
            border.color: root.hasWarnings ? Colors.nodeInvalid : Colors.nodeSelection
        }

        Rectangle {
            id: background
            anchors.fill: nodeContent
            // The overview keeps the errors visible from afar
            readonly property bool overviewError: root.lod === 2 && node.globalStatus === "ERROR"
            readonly property color errorColor: Colors.nodeStatusColors["ERROR"]
            color: overviewError ? Qt.tint(Colors.nodeBackground, Qt.rgba(errorColor.r, errorColor.g, errorColor.b, 0.3)) : Colors.nodeBackground
            border.width: 1
            border.color: overviewError ? errorColor : root.hovered && !ring.visible ? Colors.nodeTextSecondary : Colors.nodeBorder
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowColor: activePalette.shadow
                // Performance tip: Reduce blurMax (not shadowBlur) to minimize shadow blur.
                shadowBlur: 1.0  // So we keep shadowBlur at 1.0.
                shadowEnabled: true
                blurMax: 4  // large values could impact performances
            }
            radius: root.lod === 2 ? height / 2 : 8
        }

        Rectangle {
            id: nodeContent
            width: parent.width
            height: childrenRect.height
            color: "transparent"

            // Data Layout
            Column {
                id: body
                width: parent.width

                // Overview pill: status dot and label, with a constant size on screen.
                // Always instantiated (cheap, unlike the pins): entering the overview only shows it.
                Item {
                    id: pill
                    visible: root.lod === 2
                    width: parent.width
                    readonly property real unit: visible ? 1 / Math.max(root.zoom, 0.2) : 1
                    height: pillContent.height * unit

                    // Scaled rather than resized: no text layout at each zoom step
                    Item {
                        id: pillContent
                        width: pill.width / pill.unit
                        height: pillLabel.implicitHeight + 6
                        scale: pill.unit
                        transformOrigin: Item.TopLeft

                        Rectangle {
                            id: statusDot
                            x: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 7
                            height: width
                            radius: width / 2
                            color: root.statusChip ? root.statusChip.color : Colors.nodeTextSecondary
                        }

                        Label {
                            id: pillLabel
                            anchors.left: statusDot.right
                            anchors.leftMargin: 4
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.shortLabel(root.nodeLabel)
                            elide: Text.ElideRight
                            color: Colors.nodeText
                            font.family: Colors.headerFamily
                            font.weight: Font.DemiBold
                            font.pointSize: 10
                        }
                    }
                }

                // Header
                Item {
                    id: header
                    visible: root.lod < 2
                    width: parent.width
                    height: 28

                    // User color strip
                    Rectangle {
                        visible: node.color !== ""
                        x: 0
                        y: 4
                        width: 3
                        height: parent.height - 8
                        radius: 1.5
                        color: node.color !== "" ? node.color : "transparent"
                    }

                    // Header Layout
                    RowLayout {
                        id: headerLayout
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 4

                        // Category icon tile
                        Rectangle {
                            id: categoryTile
                            Layout.preferredWidth: 18
                            Layout.preferredHeight: 18
                            radius: 4
                            // Hue at 22 % on the node background, glyph in the full hue
                            color: Qt.rgba(root.tileTint.r, root.tileTint.g, root.tileTint.b, 0.22)

                            MaterialLabel {
                                anchors.centerIn: parent
                                text: MaterialIcons[root.categoryStyle.icon]
                                font.pointSize: 9
                                color: root.tileTint
                            }
                        }

                        // Node Name: has the layout priority, never narrower than 12 characters
                        Label {
                            id: nodeLabel
                            Layout.fillWidth: true
                            Layout.minimumWidth: Math.min(implicitWidth, labelMetrics.averageCharacterWidth * 12)
                            text: root.nodeLabel
                            color: Colors.nodeText
                            elide: Text.ElideRight
                            font.family: Colors.headerFamily
                            font.weight: Font.DemiBold
                            font.pointSize: 10

                            FontMetrics {
                                id: labelMetrics
                                font: nodeLabel.font
                            }

                            // Full name when elided
                            MouseArea {
                                id: nodeLabelMA
                                anchors.fill: parent
                                hoverEnabled: nodeLabel.truncated
                                acceptedButtons: Qt.NoButton
                            }
                            ToolTip.visible: nodeLabelMA.containsMouse
                            ToolTip.text: nodeLabel.text
                            ToolTip.delay: 500
                        }

                        // CompatibilityBadge icon for CompatibilityNodes
                        Loader {
                            id: compatibilityBadgeLoader
                            active: root.isCompatibilityNode
                            visible: active
                            sourceComponent: CompatibilityBadge {
                                sourceComponent: iconDelegate
                                canUpgrade: root.node.canUpgrade
                                issueDetails: root.node.issueDetails
                            }
                        }

                        // Status chip: icon only when the full chip would leave less than 100 px to the label
                        Rectangle {
                            id: statusChipItem
                            readonly property real fullWidth: chipIcon.implicitWidth + chipRow.spacing + chipWord.implicitWidth + 8
                            readonly property bool iconOnly: headerLayout.width - categoryTile.width - fullWidth - 2 * headerLayout.spacing
                                                             - (compatibilityBadgeLoader.visible ? compatibilityBadgeLoader.width + headerLayout.spacing : 0) < 100
                            visible: root.statusChip !== null
                            Layout.preferredWidth: iconOnly ? Layout.preferredHeight : fullWidth
                            Layout.preferredHeight: 18
                            radius: 9
                            color: visible ? Qt.rgba(root.statusChip.color.r, root.statusChip.color.g, root.statusChip.color.b, 0.14) : "transparent"

                            Row {
                                id: chipRow
                                anchors.centerIn: parent
                                spacing: 3
                                MaterialLabel {
                                    id: chipIcon
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.statusChip ? root.statusChip.icon : ""
                                    font.pointSize: 8
                                    color: root.statusChip ? root.statusChip.color : "transparent"
                                }
                                Label {
                                    id: chipWord
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !statusChipItem.iconOnly
                                    text: root.statusChip ? root.statusChip.text : ""
                                    font.family: Colors.fontFamily
                                    font.weight: Font.Medium
                                    font.pointSize: 8.5
                                    color: Colors.nodeText
                                }
                            }

                            MouseArea {
                                id: statusChipMA
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                            }
                            ToolTip.visible: statusChipMA.containsMouse
                            ToolTip.text: visible ? root.statusTooltip() : ""
                            ToolTip.delay: 300
                        }
                    }

                    // Flow pins: overlays straddling the header borders, they take no room from the label
                    Loader {
                        id: flowInputsLoader
                        active: node && node.hasInternalAttribute("flowInputs")
                        visible: root.lod === 0
                        x: -5  // half of the pin
                        anchors.verticalCenter: parent.verticalCenter

                        // flowInputs pin - left side of header
                        sourceComponent: AttributePin {
                            id: flowInputsHeaderPin
                            attribute: node.internalAttribute("flowInputs")
                            nodeItem: root
                            compact: true
                            displayOutputPinForInput: false

                            // globalX/Y: root is in the draggable coordinate space.
                            // All intermediate items (mouseArea, nodeContent, body, header) are at position (0,0),
                            // so only the Loader's position within the header matters.
                            property real globalX: root.x + flowInputsLoader.x
                            property real globalY: root.y + flowInputsLoader.y

                            Component.onCompleted: attributePinCreated(attribute, flowInputsHeaderPin)
                            onConnectionDragChanged: function(attribute, connectorType, dragItem) { root.connectionDragChanged(attribute, connectorType, dragItem) }
                            onDropTargetChanged: function(attribute, reason) { root.dropTargetChanged(attribute, reason) }
                            Component.onDestruction: attributePinDeleted(attribute, flowInputsHeaderPin)

                            onPressed: function(mouse) { root.pressed(mouse) }
                            onEdgeAboutToBeRemoved: function(input) { root.edgeAboutToBeRemoved(input) }
                        }
                    }

                    // flowOut pin - right side of header
                    Loader {
                        id: flowOutLoader
                        active: node && node.hasInternalAttribute("flowOutput")
                        visible: root.lod === 0
                        x: parent.width - width + 5  // half of the pin outside
                        anchors.verticalCenter: parent.verticalCenter

                        sourceComponent: AttributePin {
                            id: flowOutHeaderPin
                            attribute: node.internalAttribute("flowOutput")
                            nodeItem: root
                            compact: true

                            property real globalX: root.x + flowOutLoader.x
                            property real globalY: root.y + flowOutLoader.y

                            Component.onCompleted: attributePinCreated(attribute, flowOutHeaderPin)
                            onConnectionDragChanged: function(attribute, connectorType, dragItem) { root.connectionDragChanged(attribute, connectorType, dragItem) }
                            onDropTargetChanged: function(attribute, reason) { root.dropTargetChanged(attribute, reason) }
                            Component.onDestruction: attributePinDeleted(attribute, flowOutHeaderPin)

                            onPressed: function(mouse) { root.pressed(mouse) }
                            onEdgeAboutToBeRemoved: function(input) { root.edgeAboutToBeRemoved(input) }
                        }
                    }
                }

                // Node Chunks
                NodeChunks {
                    visible: node.isComputableType && root.lod < 2
                    targetNode: node
                    defaultColor: Colors.nodeBorder
                    chunkColorFunction: function(chunk) { return Colors.getNodeChunkColor(chunk) }
                    implicitHeight: 3
                    width: parent.width

                    ListModel {
                        id: compatibilityModel
                    }

                    model: {
                        if (!node)
                            return undefined

                        if (node.chunksCreated)
                            return node.chunks
                        else if (!node.chunksCreated && !node.isCompatibilityNode)
                            return node.chunkPlaceholder
                        else if (node.isCompatibilityNode && !["NONE"].includes(node.globalStatus)) {
                            compatibilityModel.clear()
                            compatibilityModel.append({ "object": { "statusName": node.globalStatus } })
                            return compatibilityModel
                        }

                        return undefined
                    }
                    preprocessChunk: node && node.hasPreprocessChunk ? node.preprocessChunk : null
                    postprocessChunk: node && node.hasPostprocessChunk ? node.postprocessChunk : null

                    Rectangle {
                        anchors.fill: parent
                        color: Colors.nodeBorder
                        z: -1
                    }
                }


                // Input/Output Attributes: only hidden below the full level of detail, as (re)creating
                // the pins of a whole graph takes seconds, far too long for a zoom threshold
                Item {
                    id: nodeAttributes
                    visible: root.lod === 0
                    width: parent.width - 2
                    height: childrenRect.height
                    anchors.horizontalCenter: parent.horizontalCenter

                    Column {
                        id: attributesColumn
                        width: parent.width
                        spacing: 0
                        topPadding: 4
                        bottomPadding: 4

                        Column {
                            id: outputs
                            width: parent.width
                            spacing: 0

                            property var parentPins: new Map()
                            signal parentPinsUpdated()

                            Repeater {
                                model: root.generateAttributesModel(true, outputs.parentPins)  // isOutput = true

                                delegate: Loader {
                                    id: outputLoader

                                    active: Boolean(modelData.isOutput && modelData.desc.visible)
                                    visible: {
                                        if (Boolean(modelData.enabled || modelData.hasAnyOutputLinks || modelData.hasAnyInputLinks)) {
                                            if (modelData.root && modelData.root.isExpandable) {
                                                return Boolean(outputs.parentPins.get(modelData.root.fullName) ||
                                                               modelData.hasAnyOutputLinks ||
                                                               modelData.hasAnyInputLinks)
                                            }
                                            return true
                                        }
                                        return false
                                    }

                                    anchors.right: parent.right
                                    width: outputs.width

                                    Connections {
                                        target: outputs

                                        function onParentPinsUpdated() {
                                            visible = updateChildPin(modelData, outputs.parentPins, outputLoader.item)
                                        }
                                    }

                                    sourceComponent: AttributePin {
                                        id: outPin
                                        nodeItem: root
                                        attribute: modelData
                                        expanded: Boolean(modelData.expanded)

                                        property real globalX: root.x + nodeAttributes.x + outputs.x + outputLoader.x + outPin.x
                                        property real globalY: root.y + nodeAttributes.y + outputs.y + outputLoader.y + outPin.y

                                        onIsConnectedChanged: function() {
                                            outputs.parentPinsUpdated()
                                        }

                                        onPressed: function(mouse) {
                                            root.pressed(mouse)
                                        }

                                        onClicked: function() {
                                            if (outputs.parentPins.has(modelData.fullName)) {
                                                modelData.expanded = !modelData.expanded
                                                outputs.parentPins.set(modelData.fullName, modelData.expanded)
                                                outputs.parentPinsUpdated()
                                            }
                                        }

                                        onEdgeAboutToBeRemoved: function(input) {
                                            root.edgeAboutToBeRemoved(input)
                                        }

                                        Component.onCompleted: attributePinCreated(attribute, outPin)
                                        onConnectionDragChanged: function(attribute, connectorType, dragItem) { root.connectionDragChanged(attribute, connectorType, dragItem) }
                                        onDropTargetChanged: function(attribute, reason) { root.dropTargetChanged(attribute, reason) }
                                        onChildPinCreated: function(childAttribute, outPin) { attributePinCreated(childAttribute, outPin) }
                                        Component.onDestruction: attributePinDeleted(attribute, outPin)
                                        onChildPinDeleted: function(childAttribute, outPin) { attributePinDeleted(childAttribute, outPin) }
                                    }
                                }
                            }
                        }

                        // Gap between the output and the input attributes
                        Item {
                            id: attributesGap
                            width: parent.width
                            height: 4
                            visible: outputs.height > 0 && (inputs.height > 0 || inputParams.height > 0)
                        }

                        Column {
                            id: inputs
                            width: parent.width
                            spacing: 0

                            property var parentPins: new Map()
                            signal parentPinsUpdated()

                            Repeater {
                                model: root.generateAttributesModel(false, inputs.parentPins)  // isOutput = false

                                delegate: Loader {
                                    id: inputLoader

                                    active: !modelData.isOutput && modelData.exposed && modelData.desc.visible
                                    visible: {
                                        if (Boolean(modelData.enabled)) {
                                            if (modelData.root && (modelData.root.isExpandable) ) {
                                                return Boolean(inputs.parentPins.get(modelData.root.fullName) ||
                                                               modelData.hasAnyOutputLinks ||
                                                               modelData.hasAnyInputLinks)
                                            }
                                            return true
                                        }
                                        return false
                                    }

                                    width: inputs.width

                                    Connections {
                                        target: inputs

                                        function onParentPinsUpdated() {
                                            visible = updateChildPin(modelData, inputs.parentPins, inputLoader.item)
                                        }
                                    }

                                    sourceComponent: AttributePin {
                                        id: inPin
                                        nodeItem: root
                                        attribute: modelData
                                        expanded: Boolean(modelData.expanded)

                                        property real globalX: root.x + nodeAttributes.x + inputs.x + inputLoader.x + inPin.x
                                        property real globalY: root.y + nodeAttributes.y + inputs.y + inputLoader.y + inPin.y

                                        onIsConnectedChanged: function() {
                                            inputs.parentPinsUpdated()
                                        }

                                        readOnly: Boolean(root.readOnly || modelData.isReadOnly)
                                        Component.onCompleted: attributePinCreated(attribute, inPin)
                                        onConnectionDragChanged: function(attribute, connectorType, dragItem) { root.connectionDragChanged(attribute, connectorType, dragItem) }
                                        onDropTargetChanged: function(attribute, reason) { root.dropTargetChanged(attribute, reason) }
                                        Component.onDestruction: attributePinDeleted(attribute, inPin)

                                        onPressed: function(mouse) {
                                            root.pressed(mouse)
                                        }

                                        onClicked: function() {
                                            if (inputs.parentPins.has(modelData.fullName)) {
                                                modelData.expanded = !modelData.expanded
                                                inputs.parentPins.set(modelData.fullName, modelData.expanded)
                                                inputs.parentPinsUpdated()
                                            }
                                        }

                                        onEdgeAboutToBeRemoved: function(input) {
                                            root.edgeAboutToBeRemoved(input)
                                        }

                                        onChildPinCreated: function(childAttribute, inPin) { attributePinCreated(childAttribute, inPin) }
                                        onChildPinDeleted: function(childAttribute, inPin) { attributePinDeleted(childAttribute, inPin) }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            id: inputParamsRect
                            width: parent.width
                            height: childrenRect.height
                            color: "transparent"

                            Column {
                                id: inputParams
                                width: parent.width
                                spacing: 0

                                property var parentPins: new Map()
                                signal parentPinsUpdated()

                                Repeater {
                                    model: root.generateAttributesModel(false, inputParams.parentPins)  // isOutput = false

                                    delegate: Loader {
                                        id: paramLoader

                                        // Hidden parameters are not instantiated: each pin slows down the graph panning
                                        active: !modelData.isOutput && !modelData.exposed && modelData.desc.visible && isFullyActive
                                        visible: {
                                            if (Boolean(modelData.enabled) || root.isConnected(modelData)) {
                                                if (modelData.root && modelData.root.isExpandable) {
                                                    return Boolean(inputParams.parentPins.get(modelData.root.fullName) ||
                                                                   root.isConnected(modelData))
                                                }
                                                return true
                                            }
                                            return false
                                        }

                                        // Connected parameters (or groups with a connected child) stay shown with the params collapsed
                                        property bool isFullyActive: Boolean(m.displayParams || root.isConnected(modelData))
                                        width: parent.width

                                        Connections {
                                            target: inputParams

                                            function onParentPinsUpdated() {
                                                visible = updateChildPin(modelData, inputParams.parentPins, paramLoader.item)
                                            }
                                        }

                                        sourceComponent: AttributePin {
                                            id: inParamsPin
                                            nodeItem: root
                                            attribute: modelData
                                            expanded: Boolean(modelData.expanded)

                                            property real globalX: root.x + nodeAttributes.x + inputParamsRect.x + paramLoader.x + inParamsPin.x
                                            property real globalY: root.y + nodeAttributes.y + inputParamsRect.y + paramLoader.y + inParamsPin.y

                                            onIsConnectedChanged: function() {
                                                inputParams.parentPinsUpdated()
                                            }

                                            // Row height, not childrenRect: the pin and the label are smaller than the row
                                            height: isFullyActive ? rowHeight : 0
                                            Behavior on height { PropertyAnimation {easing.type: Easing.Linear} }
                                            visible: height > 0

                                            readOnly: Boolean(root.readOnly || modelData.isReadOnly)
                                            Component.onCompleted: attributePinCreated(attribute, inParamsPin)
                                            onConnectionDragChanged: function(attribute, connectorType, dragItem) { root.connectionDragChanged(attribute, connectorType, dragItem) }
                                            onDropTargetChanged: function(attribute, reason) { root.dropTargetChanged(attribute, reason) }
                                            Component.onDestruction: attributePinDeleted(attribute, inParamsPin)

                                            onPressed: function(mouse) {
                                                root.pressed(mouse)
                                            }

                                            onClicked: function() {
                                                if (inputParams.parentPins.has(modelData.fullName)) {
                                                    modelData.expanded = !modelData.expanded
                                                    inputParams.parentPins.set(modelData.fullName, modelData.expanded)
                                                    inputParams.parentPinsUpdated()
                                                }
                                            }

                                            onEdgeAboutToBeRemoved: function(input) {
                                                root.edgeAboutToBeRemoved(input)
                                            }

                                            onChildPinCreated: function(childAttribute, inParamsPin) { attributePinCreated(childAttribute, inParamsPin) }
                                            onChildPinDeleted: function(childAttribute, inParamsPin) { attributePinDeleted(childAttribute, inParamsPin) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                NodeFooter {
                    visible: root.lod === 0
                    width: parent.width
                    nodeItem: root
                    meta: root.chunkStats.done > 0 || node.globalStatus === "RUNNING" ? root.chunkStats.done + "/" + root.chunkStats.count + " · " + root.formatDuration(root.chunkStats.elapsed) : ""
                    modifiedCount: root.modifiedParamsCount
                    expanded: m.displayParams
                    onToggled: m.displayParams = !m.displayParams
                }
            }
        }
    }

    // Inline component: no access to the ids of this file
    component AggregatedPort: Item {
        id: port
        property var nodeItem
        property bool isOutput: false
        property real centerY: 0
        // Same interface as the attribute pins, for the edges anchoring
        readonly property var attribute: null
        readonly property real globalX: nodeItem.x + x
        readonly property real globalY: nodeItem.y + y
        readonly property point inputAnchorPos: Qt.point(width / 2, height / 2)
        readonly property point outputAnchorPos: inputAnchorPos

        visible: nodeItem.lod > 0
        width: 10
        height: 10
        x: isOutput ? nodeItem.width - width / 2 : -width / 2
        y: centerY - height / 2

        Rectangle {
            anchors.fill: parent
            visible: port.nodeItem.lod === 1
            radius: width / 2
            color: portMA.containsMouse ? Colors.nodeText : Colors.nodeTextSecondary
        }

        // No connection from here: dragging the port zooms in on the node, where its attribute pins can be used
        MouseArea {
            id: portMA
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            property point pressPosition
            property bool zoomed: false
            onPressed: function(mouse) {
                pressPosition = Qt.point(mouse.x, mouse.y)
                zoomed = false
            }
            onPositionChanged: function(mouse) {
                if (pressed && !zoomed && Math.hypot(mouse.x - pressPosition.x, mouse.y - pressPosition.y) >= 5) {
                    zoomed = true
                    port.nodeItem.zoomRequested()
                }
            }
            ToolTip.visible: containsMouse
            ToolTip.text: "Drag to zoom in and connect the attributes"
            ToolTip.delay: 500
        }
    }

    // Centered on the header; in the overview, same position, near the top of the pill: as the pill keeps a
    // constant size on screen, a port centered on it would move all the edges at each zoom step
    AggregatedPort {
        id: inputPortItem
        nodeItem: root
        centerY: header.height / 2
    }

    AggregatedPort {
        id: outputPortItem
        nodeItem: root
        isOutput: true
        centerY: header.height / 2
    }

    /// Set to true by the GraphEditor's DropArea when files are dragged over this InputNode
    property bool inputNodeDragHover: false

    // Highlight overlay shown when files are dragged over this InputNode
    Rectangle {
        anchors.fill: mouseArea
        visible: root.node && root.node.isInputNode && root.inputNodeDragHover
        color: Colors.sysPalette.highlight
        opacity: 0.35
        radius: background.radius
    }
}
