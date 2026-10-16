import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Utils 1.0
import MaterialIcons 2.2
import "AnySetUtils.js" as AnySetUtils

/**
 * The representation of an Attribute on a Node.
 */

RowLayout {
    id: root

    property var nodeItem
    property var attribute
    property bool expanded: false
    property bool readOnly: false
    /// Whether to display an output pin for input attribute
    property bool displayOutputPinForInput: true
    /// Compact mode: hides the attribute label, showing only the connection circle.
    /// Useful for embedding the pin in space-constrained areas like the node header.
    property bool compact: false

    // position of the anchor for attaching and edge to this attribute pin
    readonly property point inputAnchorPos: Qt.point(inputAnchor.x + inputAnchor.width / 2,
                                                     inputAnchor.y + inputAnchor.height / 2)

    readonly property point outputAnchorPos: Qt.point(outputAnchor.x + root.pinOffset + outputAnchor.width / 2,
                                                      outputAnchor.y + outputAnchor.height / 2)

    readonly property real rowHeight: 16
    readonly property real pinSize: 10
    // Non-compact pins straddle the node border: shifted outward by half a pin plus the 1 px inset of the attributes
    readonly property real pinOffset: compact ? 0 : pinSize / 2 + 1
    readonly property color typeColor: compact ? (nodeItem ? nodeItem.headerTextSecondaryColor : GraphTheme.nodeTextSecondary) : GraphTheme.dataTypeColor(attribute ? attribute.dataType : "", nodeItem ? nodeItem.bodyColor : undefined)

    // Connection capture zone around the pin center: 24 px wide, and vertically up to halfway to the neighbour
    // rows (adjacent rows, or across the outputs/inputs gap), extended to 12 px above the first row and below the last one
    readonly property real captureHalfWidth: 12
    readonly property real relativeY: typeof globalY !== "undefined" && nodeItem ? globalY - nodeItem.y : -1
    readonly property bool isFirstRow: !!nodeItem && Math.abs(relativeY - nodeItem.attributesTop) < 1
    readonly property bool isLastRow: !!nodeItem && relativeY + rowHeight > nodeItem.attributesBottom - 1
    readonly property real halfGap: nodeItem ? (nodeItem.attributesGapBottom - nodeItem.attributesGapTop) / 2 : 0
    readonly property real captureTop: !nodeItem || isFirstRow ? captureHalfWidth
                                                  : rowHeight / 2 + (Math.abs(relativeY - nodeItem.attributesGapBottom) < 1 ? halfGap : 0)
    readonly property real captureBottom: !nodeItem || isLastRow ? captureHalfWidth
                                                    : rowHeight / 2 + (Math.abs(relativeY + rowHeight - nodeItem.attributesGapTop) < 1 ? halfGap : 0)

    // Connection guide, set by the Graph Editor while an edge is being dragged
    readonly property bool isDragSource: inputConnectMA.dragTriggered || outputConnectMA.dragTriggered
    readonly property bool guiding: !!nodeItem && !!nodeItem.compatibleAttributeUuids
    readonly property bool isCompatible: guiding && nodeItem.compatibleAttributeUuids.has(attribute.uuid)
    // Header flow pins (compact) are hidden unless connected, the node hovered or a compatible drag target;
    // their drag zone stays active while hidden
    readonly property bool hiddenFlowPin: compact && !isConnected && !isDragSource && !isCompatible && !(nodeItem && nodeItem.hovered)
    opacity: hiddenFlowPin ? 0 : guiding && !isCompatible && !isDragSource ? 0.35 : 1.0

    readonly property bool isList: attribute && attribute.type === "ListAttribute"
    readonly property bool isExpandable: attribute && attribute.isExpandable === true
    readonly property bool isDynamic: !!attribute.desc && !!attribute.desc.isCustomAttribute
    readonly property bool isAnySetChild: !!attribute && !!attribute.root && attribute.root.type === "AnySet"
    readonly property bool isConnected: attribute.hasAnyInputLinks || attribute.hasAnyOutputLinks

    signal childPinCreated(var childAttribute, var pin)
    signal childPinDeleted(var childAttribute, var pin)

    signal pressed(var mouse)
    signal edgeAboutToBeRemoved(var input)
    signal clicked()
    /// An edge started (attribute set) or stopped (attribute null) being dragged from this pin
    signal connectionDragChanged(var attribute, string connectorType, var dragItem)
    /// The dragged edge entered (attribute set) or left (attribute null) this pin, with the refusal reason if any
    signal dropTargetChanged(var attribute, string reason)

    onStateChanged: {
        if (state === "DraggingInput")
            connectionDragChanged(attribute, "input", inputDragTarget)
        else if (state === "DraggingOutput")
            connectionDragChanged(attribute, "output", outputDragTarget)
        else
            connectionDragChanged(null, "", null)
    }

    Component {
        id: removeAnySetAttributeMenuComp
        Menu {
            id: anySetMenu

            property real preferredX: 0
            property real preferredY: 0

            MenuItem {
                text: "Move Up"
                enabled: AnySetUtils.canMoveBy(attribute, -1)
                onTriggered: _currentScene.moveAnySetAttribute(attribute, -1)
            }
            MenuItem {
                text: "Move Down"
                enabled: AnySetUtils.canMoveBy(attribute, 1)
                onTriggered: _currentScene.moveAnySetAttribute(attribute, 1)
            }
            MenuSeparator {}
            MenuItem {
                text: "Rename Attribute"
                enabled: root.isAnySetChild
                onTriggered: {
                    var dialog = renameAnySetAttributeDialogComp.createObject(Overlay.overlay, {
                        "targetAttribute": attribute,
                        "preferredX": anySetMenu.preferredX,
                        "preferredY": anySetMenu.preferredY
                    })
                    dialog.open()
                }
            }
            MenuItem {
                text: "Remove Attribute"
                enabled: root.isAnySetChild
                onTriggered: _currentScene.removeAnySetAttribute(attribute)
            }
        }
    }

    Component {
        id: renameAnySetAttributeDialogComp
        Dialog {
            id: renameDialog

            property var targetAttribute: null
            property real preferredX: 0
            property real preferredY: 0

            title: "Rename Attribute"
            modal: true
            parent: Overlay.overlay
            contentWidth: 280
            x: parent ? Math.max(0, Math.min(preferredX, parent.width - width)) : 0
            y: parent ? Math.max(0, Math.min(preferredY, parent.height - height)) : 0
            standardButtons: Dialog.Ok | Dialog.Cancel
            closePolicy: Popup.CloseOnEscape

            GridLayout {
                columns: 2
                columnSpacing: 8
                rowSpacing: 8
                width: renameDialog.contentWidth

                Label {
                    text: "Name"
                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                }
                TextField {
                    id: nameField
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: renameDialog.targetAttribute ? renameDialog.targetAttribute.name : ""
                    selectByMouse: true
                    validator: RegularExpressionValidator { regularExpression: /^[A-Za-z_][A-Za-z0-9_]*$/ }
                    onAccepted: renameDialog.accept()
                }

                Label {
                    text: "Label"
                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                }
                TextField {
                    id: labelField
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: renameDialog.targetAttribute ? renameDialog.targetAttribute.label : ""
                    selectByMouse: true
                    onAccepted: renameDialog.accept()
                }
            }

            onOpened: {
                nameField.forceActiveFocus()
                nameField.selectAll()
            }

            onAccepted: {
                if (targetAttribute && nameField.acceptableInput && labelField.text.trim() !== "") {
                    _currentScene.renameAnySetAttribute(targetAttribute, nameField.text.trim(), labelField.text.trim())
                }
                destroy()
            }

            onRejected: destroy()
        }
    }

    objectName: attribute ? attribute.name + "." : ""
    layoutDirection: Qt.LeftToRight
    spacing: 3
    height: rowHeight

    HoverHandler {
        id: rowHover
        enabled: root.displayOutputPinForInput && !root.attribute.isOutput
    }

    // Children connected under a collapsed group
    function hasConnectedChildren(output) {
        if (!root.isExpandable || root.expanded || root.isConnected || !attribute)
            return false
        for (var i = 0; i < attribute.flatStaticChildren.length; ++i) {
            const child = attribute.flatStaticChildren[i]
            if (output ? child.hasAnyOutputLinks : child.hasAnyInputLinks)
                return true
        }
        return false
    }

    ToolTip {
        text: attribute.fullName + ": " + attribute.type
        // Hidden while dragging: the Graph Editor displays the connection info
        visible: nameLabel.hovered && !root.isDragSource
        delay: 500

        x: nameLabel.x
        y: nameLabel.y + nameLabel.height
    }

    // Instantiate empty Items for each child attribute
    Repeater {
        id: childrenRepeater
        model: root.isList && !root.attribute.isLink ? root.attribute.value : 0
        onItemAdded: function(index, item) { childPinCreated(item.childAttribute, root) }
        onItemRemoved: function(index, item) { childPinDeleted(item.childAttribute, root) }
        delegate: Item {
            property var childAttribute: object
            visible: false
        }
    }

    Item {
        width: childrenRect.width
        Layout.alignment: Qt.AlignVCenter
        Layout.fillWidth: !root.compact
        Layout.fillHeight: true

        PinShape {
            id: inputAnchor
            outlined: !!root.nodeItem && GraphTheme.contrast(root.typeColor, root.nodeItem.bodyColor) < 3
            visible: !root.attribute.isOutput

            x: -root.pinOffset
            y: (root.rowHeight - height) / 2
            size: root.pinSize
            shapeVisible: !root.isDynamic
            pinColor: root.typeColor
            isList: root.isList
            isGroup: root.isExpandable
            isFlow: root.compact
            filled: root.attribute.hasAnyInputLinks
            halfFilled: root.hasConnectedChildren(false)
            hovered: inputConnectMA.containsMouse || inputConnectMA.drag.active || (inputDropArea.containsDrag && inputDropArea.acceptableDrop)
            compatible: root.isCompatible

            DropArea {
                id: inputDropArea

                property bool acceptableDrop: false

                // Add negative margins for DropArea to make the connection zone easier to reach
                anchors.fill: parent
                anchors.leftMargin: root.compact ? -2 : -(root.captureHalfWidth - root.pinSize / 2)
                anchors.topMargin: root.compact ? -2 : -(root.captureTop - root.pinSize / 2)
                anchors.bottomMargin: root.compact ? -2 : -(root.captureBottom - root.pinSize / 2)
                // Add horizontal negative margins according to the current layout
                anchors.rightMargin: -root.width * 0.3

                keys: [inputDragTarget.objectName]
                onEntered: function(drag) {
                    // Same rules as the connection guide computed by the Graph Editor
                    const reason = drag.source.objectName != inputDragTarget.objectName ? "not a connector" :
                                   _currentScene.connectionError(drag.source.attribute, drag.source.connectorType, inputDragTarget.attribute, "input")
                    if (reason) {
                        // Refuse attributes connection
                        drag.accepted = false
                    } else if (inputDragTarget.attribute.isLink) {  // Already connected attribute
                        root.edgeAboutToBeRemoved(inputDragTarget.attribute)
                    }
                    inputDropArea.acceptableDrop = drag.accepted
                    root.dropTargetChanged(inputDragTarget.attribute, reason)
                }

                onExited: {
                    if (inputDragTarget.attribute.isLink) {  // Already connected attribute
                        root.edgeAboutToBeRemoved(undefined)
                    }
                    acceptableDrop = false
                    drag.source.dropAccepted = false
                    root.dropTargetChanged(null, "")
                }

                onDropped: function(drop) {
                    root.edgeAboutToBeRemoved(undefined)
                    root.dropTargetChanged(null, "")
                    _currentScene.addEdge(drag.source.attribute, inputDragTarget.attribute)
                }
            }

            Item {
                id: inputDragTarget
                objectName: "edgeConnector"
                readonly property string connectorType: "input"
                readonly property alias attribute: root.attribute
                readonly property alias nodeItem: root.nodeItem
                readonly property bool isOutput: Boolean(attribute.isOutput)
                readonly property alias isList: root.isList
                readonly property alias isExpandable: root.isExpandable
                property bool dragAccepted: false
                anchors.verticalCenter: parent.verticalCenter
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                height: parent.height
                Drag.keys: [inputDragTarget.objectName]
                Drag.active: inputConnectMA.drag.active
                Drag.hotSpot.x: width * 0.5
                Drag.hotSpot.y: height * 0.5
            }

            MouseArea {
                id: inputConnectMA
                drag.target: root.attribute.isReadOnly ? undefined : inputDragTarget
                drag.threshold: 0
                // Move the edge's tip straight to the current mouse position instead of waiting after the drag operation has started
                drag.smoothed: false
                enabled: !root.readOnly
                anchors.fill: parent
                hoverEnabled: root.visible

                // Use the same negative margins as DropArea to ease pin selection
                anchors.leftMargin: inputDropArea.anchors.leftMargin
                anchors.rightMargin: inputDropArea.anchors.rightMargin
                anchors.topMargin: inputDropArea.anchors.topMargin
                anchors.bottomMargin: inputDropArea.anchors.bottomMargin

                property bool dragTriggered: false  // An edge is being dragged from the input connector
                property bool isPressed: false  // The mouse has been pressed but not released yet
                property double initialX: 0.0
                property double initialY: 0.0

                onPressed: function(mouse) {
                    root.pressed(mouse)
                    isPressed = true
                    initialX = mouse.x
                    initialY = mouse.y
                }

                onReleased: {
                    inputDragTarget.Drag.drop()
                    isPressed = false
                    dragTriggered = false
                }

                onClicked: function() {
                    root.clicked()
                }

                onPositionChanged: function(mouse) {
                    // If there has been a significant move (5px along the -X or -Y axis) while the
                    // mouse is being pressed, then we can consider being in the dragging state
                    if (isPressed && (Math.abs(mouse.x - initialX) >= 5.0 || Math.abs(mouse.y - initialY) >= 5.0)) {
                        dragTriggered = true
                    }
                }
            }

            Edge {
                id: inputConnectEdge
                visible: false
                point1x: inputDragTarget.x + inputDragTarget.width / 2
                point1y: inputDragTarget.y + inputDragTarget.height / 2
                point2x: parent.width / 2
                point2y: parent.width / 2
                color: root.typeColor
                thickness: outputDragTarget.dropAccepted ? 2 : 1
            }
        }
    }

    // Attribute name
    Item {
        id: nameContainer
        implicitHeight: childrenRect.height
        implicitWidth: childrenRect.width
        visible: !root.compact
        Layout.fillWidth: !root.compact
        Layout.maximumWidth: root.compact ? 0 : Number.POSITIVE_INFINITY
        Layout.fillHeight: true
        Layout.alignment: Qt.AlignVCenter

        MaterialToolLabel {
            id: nameLabel

            anchors.fill: parent
            Layout.fillWidth: true
            Layout.fillHeight: true
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 0
            labelIconRow.layoutDirection: root.attribute.isOutput ? Qt.RightToLeft : Qt.LeftToRight
            labelIconRow.spacing: 0

            enabled: !root.readOnly
            visible: true

            // Allow to trigger a change of state once the parent is ready, ensuring the correct width of the
            // elements upon their first display without waiting for a mouse interaction
            property bool parentNotReady: nameContainer.width == 0

            property bool hovered: (nameLabel.visible && parentNotReady) || (inputConnectMA.containsMouse ||
                                                      inputConnectMA.drag.active ||
                                                      inputDropArea.containsDrag ||
                                                      outputConnectMA.containsMouse ||
                                                      outputConnectMA.drag.active ||
                                                      outputDropArea.containsDrag)

            labelIconColor: {
                if ((root.attribute.hasAnyOutputLinks || root.attribute.isLink) && !root.attribute.enabled) {
                    return Colors.lightgrey
                } else if (hovered) {
                    return palette.highlight
                }
                return root.nodeItem ? root.nodeItem.textColor : palette.text
            }
            labelIconMouseArea.enabled: false  // Prevent mixing mouse interactions between the label and the pin context

            // Text
            label.text: root.attribute.label
            label.font.family: GraphTheme.fontFamily
            label.font.weight: Font.Normal
            label.font.pointSize: 9
            label.elide: hovered ? Text.ElideNone : Text.ElideMiddle
            label.horizontalAlignment: root.attribute && root.attribute.isOutput ? Text.AlignRight : Text.AlignLeft
            label.verticalAlignment: Text.AlignVCenter
            label.visible: true
            label.font.italic: root.isDynamic || (!!attribute.root && !!attribute.root.desc && !!attribute.root.desc.isCustomAttribute)

            // Icon
            iconText: {
                if (root.isExpandable) {
                    return root.expanded ? MaterialIcons.expand_more : MaterialIcons.chevron_right
                }
                return ""
            }
            iconSize: 9
            icon.horizontalAlignment: root.attribute && root.attribute.isOutput ? Text.AlignRight : Text.AlignLeft
            icon.verticalAlignment: Text.AlignVCenter

            // Handle tree view for nested attributes
            property int groupPaddingWidth: root.attribute.depth * 10
            icon.leftPadding: root.attribute.isOutput ? 0 : groupPaddingWidth
            icon.rightPadding: root.attribute.isOutput ? groupPaddingWidth : 0
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.isAnySetChild
            acceptedButtons: Qt.RightButton
            onClicked: function(mouse) {
                var menu = removeAnySetAttributeMenuComp.createObject(nameContainer)
                var position = mapToItem(Overlay.overlay, mouse.x, mouse.y)
                menu.preferredX = position.x
                menu.preferredY = position.y
                menu.parent = nameContainer
                menu.popup()
            }
        }
    }

    PinShape {
        id: outputAnchor
        outlined: !!root.nodeItem && GraphTheme.contrast(root.typeColor, root.nodeItem.bodyColor) < 3

        visible: root.displayOutputPinForInput || root.attribute.isOutput
        // Output pin of an input attribute: only shown when it carries an edge, the row is hovered or during a
        // compatible drag; its drag zone stays active while hidden
        opacity: root.attribute.isOutput || root.compact || root.attribute.hasAnyOutputLinks || rowHover.hovered || root.isCompatible ||
                 outputConnectMA.containsMouse || outputConnectMA.drag.active ? 1 : 0
        size: root.pinSize
        Layout.alignment: Qt.AlignVCenter
        // Straddle the node border without changing the layout
        transform: Translate { x: root.pinOffset }

        pinColor: root.typeColor
        isList: root.isList
        isGroup: root.isExpandable
        isFlow: root.compact
        filled: root.attribute.hasAnyOutputLinks
        halfFilled: root.hasConnectedChildren(true)
        hovered: root.attribute.enabled && (outputConnectMA.containsMouse || outputConnectMA.drag.active ||
                                            (outputDropArea.containsDrag && outputDropArea.acceptableDrop))
        compatible: root.isCompatible

        DropArea {
            id: outputDropArea

            property bool acceptableDrop: false

            // Add negative margins for DropArea to make the connection zone easier to reach
            anchors.fill: parent
            anchors.rightMargin: root.compact ? -2 : -(root.captureHalfWidth - root.pinSize / 2)
            anchors.topMargin: root.compact ? -2 : -(root.captureTop - root.pinSize / 2)
            anchors.bottomMargin: root.compact ? -2 : -(root.captureBottom - root.pinSize / 2)
            // Add horizontal negative margins according to the current layout
            anchors.leftMargin: -root.width * 0.2

            keys: [outputDragTarget.objectName]
            onEntered: function(drag) {
                // Same rules as the connection guide computed by the Graph Editor
                const reason = drag.source.objectName != outputDragTarget.objectName ? "not a connector" :
                               _currentScene.connectionError(drag.source.attribute, drag.source.connectorType, outputDragTarget.attribute, "output")
                if (reason) {
                    // Refuse attributes connection
                    drag.accepted = false
                } else if (drag.source.attribute.isLink) {  // Already connected attribute
                    root.edgeAboutToBeRemoved(drag.source.attribute)
                }
                outputDropArea.acceptableDrop = drag.accepted
                root.dropTargetChanged(outputDragTarget.attribute, reason)
            }
            onExited: {
                root.edgeAboutToBeRemoved(undefined)
                acceptableDrop = false
                root.dropTargetChanged(null, "")
            }

            onDropped: function(drop) {
                root.edgeAboutToBeRemoved(undefined)
                root.dropTargetChanged(null, "")
                _currentScene.addEdge(outputDragTarget.attribute, drag.source.attribute)
            }
        }

        Item {
            id: outputDragTarget
            objectName: "edgeConnector"
            readonly property string connectorType: "output"
            readonly property alias attribute: root.attribute
            readonly property alias nodeItem: root.nodeItem
            readonly property bool isOutput: Boolean(attribute.isOutput)
            readonly property alias isList: root.isList
            readonly property alias isExpandable: root.isExpandable
            property bool dropAccepted: false
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: parent.height
            Drag.keys: [outputDragTarget.objectName]
            Drag.active: outputConnectMA.drag.active
            Drag.hotSpot.x: width * 0.5
            Drag.hotSpot.y: height * 0.5
        }

        MouseArea {
            id: outputConnectMA
            drag.target: outputDragTarget
            drag.threshold: 0
            // Move the edge's tip straight to the current mouse position instead of waiting after the drag operation has started
            drag.smoothed: false
            anchors.fill: parent
            // Use the same negative margins as DropArea to ease pin selection
            anchors.leftMargin: outputDropArea.anchors.leftMargin
            anchors.rightMargin: outputDropArea.anchors.rightMargin
            anchors.topMargin: outputDropArea.anchors.topMargin
            anchors.bottomMargin: outputDropArea.anchors.bottomMargin

            hoverEnabled: root.visible

            property bool dragTriggered: false  // An edge is being dragged from the output connector
            property bool isPressed: false   // The mouse has been pressed but not released yet
            property double initialX: 0.0
            property double initialY: 0.0

            onPressed: function(mouse) {
                root.pressed(mouse)
                isPressed = true
                initialX = mouse.x
                initialY = mouse.y
            }

            onReleased: function(mouse) {
                outputDragTarget.Drag.drop()
                isPressed = false
                dragTriggered = false
            }

            onClicked: function() {
                root.clicked()
            }

            onPositionChanged: function(mouse) {
                // If there has been a significant move (5px along the -X or -Y axis) while the mouse is being
                // pressed, then we can consider being in the dragging state.
                if (isPressed && (Math.abs(mouse.x - initialX) >= 5.0 || Math.abs(mouse.y - initialY) >= 5.0)) {
                    dragTriggered = true
                }
            }
        }

        Edge {
            id: outputConnectEdge
            visible: false
            point1x: parent.width / 2
            point1y: parent.width / 2
            point2x: outputDragTarget.x + outputDragTarget.width / 2
            point2y: outputDragTarget.y + outputDragTarget.height / 2
            color: root.typeColor
            thickness: outputDragTarget.dropAccepted ? 2 : 1
        }
    }

    state: inputConnectMA.dragTriggered ? "DraggingInput" : outputConnectMA.dragTriggered ? "DraggingOutput" : ""

    states: [
        State {
            name: ""
            AnchorChanges {
                target: outputDragTarget
                anchors.horizontalCenter: outputAnchor.horizontalCenter
                anchors.verticalCenter: outputAnchor.verticalCenter
            }
            AnchorChanges {
                target: inputDragTarget
                anchors.horizontalCenter: inputAnchor.horizontalCenter
                anchors.verticalCenter: inputAnchor.verticalCenter
            }
            PropertyChanges {
                target: inputDragTarget
                x: 0
                y: 0
            }
            PropertyChanges {
                target: outputDragTarget
                x: 0
                y: 0
            }
        },

        State {
            name: "DraggingInput"
            AnchorChanges {
                target: inputDragTarget
                anchors.horizontalCenter: undefined
                anchors.verticalCenter: undefined
            }
            PropertyChanges {
                target: inputConnectEdge
                z: 100
                visible: true
            }
            StateChangeScript {
                script: {
                    // Add the right offset if the initial click is not exactly at the center of the connection circle.
                    var pos = inputDragTarget.mapFromItem(inputConnectMA, inputConnectMA.mouseX, inputConnectMA.mouseY);
                    inputDragTarget.x = pos.x - inputDragTarget.width / 2;
                    inputDragTarget.y = pos.y - inputDragTarget.height / 2;
                }
            }
        },
        State {
            name: "DraggingOutput"
            AnchorChanges {
                target: outputDragTarget
                anchors.horizontalCenter: undefined
                anchors.verticalCenter: undefined
            }
            PropertyChanges {
                target: outputConnectEdge
                z: 100
                visible: true
            }
            StateChangeScript {
                script: {
                    var pos = outputDragTarget.mapFromItem(outputConnectMA, outputConnectMA.mouseX, outputConnectMA.mouseY);
                    outputDragTarget.x = pos.x - outputDragTarget.width / 2;
                    outputDragTarget.y = pos.y - outputDragTarget.height / 2;
                }
            }
        }
    ]
}
