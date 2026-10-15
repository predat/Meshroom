import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import MaterialIcons 2.2
import Utils 1.0

/**
 * Footer of a graph Node: computation meta (n/N · elapsed), the parameters toggle and the state badges
 * (lock, cloud, duplicates, comment, warnings, visibility, beta/user), 2 at most then a "⋯n" overflow popup.
 */

Item {
    id: root

    /// The Node delegate this footer belongs to
    property Item nodeItem
    readonly property var node: nodeItem ? nodeItem.node : null
    /// Monospace meta text, empty when the node has not been computed
    property string meta: ""
    /// Number of hidden parameters which differ from their default value
    property int modifiedCount: 0
    /// Whether the hidden parameters are displayed
    property bool expanded: false

    signal toggled()

    readonly property int maxBadges: 2
    readonly property real margins: 6

    implicitHeight: 22

    readonly property bool hasOutputsToDisplay: !!node && (node.hasImageOutput || node.has3DOutput || node.hasSequenceOutput || node.hasTextOutput)
    readonly property bool displayable: !!node && (!node.isComputableType || (node.chunks.count > 0 && node.globalStatus === "SUCCESS"))

    function visibilityTooltip() {
        if ((node.hasImageOutput || node.hasSequenceOutput) && !node.has3DOutput)
            return displayable ? "Double-click on this node to load its outputs in the Image Viewer." : "This node has image outputs."
        else if (node.has3DOutput && !node.hasImageOutput && !node.hasSequenceOutput)
            return displayable ? "Double-click on this node to load its outputs in the 3D Viewer." : "This node has 3D outputs."
        else if (node.hasTextOutput && !node.hasImageOutput && !node.hasSequenceOutput && !node.has3DOutput)
            return displayable ? "Double-click on this node to load its outputs in the Text Viewer." : "This node has text outputs."
        else  // Handle case where a node might have both 2D and 3D outputs
            return displayable ? "Double-click on this node to load its outputs in the Image or 3D Viewer." : "This node has image and 3D outputs."
    }

    // Active badges, by priority: { icon, color, text, kind }
    readonly property var badges: {
        const list = []
        if (!node)
            return list
        if (nodeItem.readOnly)
            list.push({ "icon": MaterialIcons.lock, "color": Colors.nodeStatusColors["ERROR"], "text": "Locked", "kind": "" })
        if (node.isExternal)
            list.push({ "icon": MaterialIcons.cloud, "color": Colors.nodeTextSecondary, "text": "Computed Externally", "kind": "" })
        if (node.hasDuplicates)
            list.push({ "icon": MaterialIcons.layers, "color": Colors.nodeTextSecondary,
                        "text": "<b>Shares internal folder (data) with other node(s). Hold click for details.</b>", "kind": "duplicates" })
        if (node.comment !== "" || node.invalidation !== "")
            list.push({ "icon": MaterialIcons.comment, "color": Colors.nodeTextSecondary,
                        "text": nodeItem.formatInternalAttributesTooltip(node.invalidation, node.comment), "kind": "comment" })
        if (nodeItem.hasWarnings)
            list.push({ "icon": MaterialIcons.fmd_bad, "color": Colors.nodeInvalid, "text": "Some attribute validations are failing for this node.", "kind": "" })
        if (hasOutputsToDisplay)
            list.push({ "icon": MaterialIcons.visibility, "color": displayable ? Colors.nodeText : Colors.nodeTextSecondary,
                        "text": visibilityTooltip(), "kind": "" })
        if (node.nodeVersionType === NodeVersionType.BETA)
            list.push({ "icon": MaterialIcons.science, "color": Colors.nodeInvalid, "text": "This node is in beta version.", "kind": "" })
        else if (node.nodeVersionType === NodeVersionType.USER)
            list.push({ "icon": MaterialIcons.new_releases, "color": Colors.nodeStatusColors["ERROR"],
                        "text": "This node is a user plugin. It is not maintained by the core team.", "kind": "" })
        return list
    }

    // Separator
    Rectangle {
        width: parent.width
        height: 1
        color: Colors.nodeBorder
    }

    Label {
        id: metaLabel
        anchors.left: parent.left
        anchors.leftMargin: root.margins
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, root.width - badgesRow.implicitWidth - toggleArea.width - 4 * root.margins)
        text: root.meta
        visible: text !== ""
        elide: Text.ElideRight
        font.family: Colors.monoFamily
        font.pointSize: 8
        color: Colors.nodeTextSecondary
    }

    // Measures the full toggle label, to fall back to the compact one when it does not fit
    Label {
        id: fullLabel
        visible: false
        text: (root.expanded ? "▾" : "▸") + " Params" + (root.modifiedCount > 0 ? " · " + root.modifiedCount + " modified" : "")
        font.family: Colors.fontFamily
        font.weight: Font.Medium
        font.pointSize: 8.5
    }

    MouseArea {
        id: toggleArea
        readonly property bool compact: root.width - (metaLabel.visible ? metaLabel.implicitWidth + root.margins : 0) - badgesRow.implicitWidth
                                        - 4 * root.margins - modifiedDot.width < fullLabel.implicitWidth
        anchors.left: metaLabel.visible ? metaLabel.right : parent.left
        anchors.leftMargin: root.margins
        anchors.verticalCenter: parent.verticalCenter
        width: toggleRow.implicitWidth
        height: parent.height
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()

        ToolTip.visible: containsMouse && compact
        ToolTip.text: "Params" + (root.modifiedCount > 0 ? " · " + root.modifiedCount + " modified" : "")
        ToolTip.delay: 300

        Row {
            id: toggleRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            Label {
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    if (!toggleArea.compact)
                        return fullLabel.text
                    return (root.expanded ? "▾" : "▸") + (root.modifiedCount > 0 ? " " + root.modifiedCount : "")
                }
                font.family: Colors.fontFamily
                font.weight: Font.Medium
                font.pointSize: 8.5
                color: toggleArea.containsMouse ? Colors.nodeText : Colors.nodeTextSecondary
            }
            Rectangle {
                id: modifiedDot
                anchors.verticalCenter: parent.verticalCenter
                visible: root.modifiedCount > 0
                width: 6
                height: 6
                radius: 3
                color: Colors.nodeModified
            }
        }
    }

    Row {
        id: badgesRow
        anchors.right: parent.right
        anchors.rightMargin: root.margins - 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Repeater {
            model: root.badges.slice(0, root.maxBadges)
            delegate: badgeComponent
        }

        // Overflow: lists every badge with its tooltip
        Label {
            visible: root.badges.length > root.maxBadges
            text: "⋯" + (root.badges.length - root.maxBadges)
            padding: 2
            font.family: Colors.fontFamily
            font.weight: Font.Medium
            font.pointSize: 8.5
            color: overflowMA.containsMouse ? Colors.nodeText : Colors.nodeTextSecondary
            MouseArea {
                id: overflowMA
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: overflowPopup.open()
            }
            ToolTip.visible: overflowMA.containsMouse && !overflowPopup.visible
            ToolTip.text: (root.badges.length - root.maxBadges) + " more"
            ToolTip.delay: 300

            Popup {
                id: overflowPopup
                y: parent.height
                padding: 6
                ColumnLayout {
                    spacing: 4
                    Repeater {
                        model: overflowPopup.visible ? root.badges : []
                        delegate: RowLayout {
                            spacing: 6
                            MaterialLabel {
                                Layout.alignment: Qt.AlignTop
                                text: modelData.icon
                                font.pointSize: 9
                                color: modelData.color
                            }
                            Label {
                                Layout.maximumWidth: 360
                                text: modelData.kind === "duplicates" ? root.nodeItem.generateDuplicateList() : modelData.text
                                textFormat: Text.RichText
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: badgeComponent

        MaterialLabel {
            id: badge
            property string toolTipText: modelData.text
            text: modelData.icon
            padding: 2
            font.pointSize: 8
            color: modelData.color

            MouseArea {
                id: badgeMA
                anchors.fill: parent
                hoverEnabled: true
                // Duplicates: hold click to list the nodes sharing the same internal folder
                onPressed: function(mouse) {
                    if (modelData.kind !== "duplicates") {
                        mouse.accepted = false
                        return
                    }
                    offsetReleased.running = false
                    badge.toolTipText = root.nodeItem.generateDuplicateList()
                }
                onReleased: offsetReleased.running = true
                onCanceled: offsetReleased.running = true
            }

            // Avoid to change the text too quickly when the click is released
            Timer {
                id: offsetReleased
                interval: 750
                onTriggered: badge.toolTipText = Qt.binding(function() { return modelData.text })
            }

            ToolTip {
                visible: badgeMA.containsMouse || badgeMA.pressed
                text: badge.toolTipText
                delay: 300
                // Forces word-wrap for long comments
                width: modelData.kind === "comment" ? 400 : implicitWidth
            }
        }
    }
}
