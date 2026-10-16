import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Controls 1.0
import MaterialIcons 2.2
import Utils 1.0

/**
 * Attributes of a node in collapsible groups: Main (inputs), Advanced (advanced inputs) and Outputs,
 * each with its count of modified values and a reset link. The collapsed state is persisted by node type.
 */

ScrollView {
    id: root

    property var node: null
    property bool readOnly: false
    property string filterText: ""

    signal upgradeRequest()
    signal attributeDoubleClicked(var mouse, var attribute)
    signal inAttributeClicked(var srcItem, var mouse, var inAttributes)
    signal outAttributeClicked(var srcItem, var mouse, var outAttributes)
    signal showInViewer(var attribute)

    // Advanced is collapsed by default, as the advanced attributes were hidden by default
    readonly property var groups: [
        { "name": "main", "title": "Main", "collapsed": false },
        { "name": "advanced", "title": "Advanced", "collapsed": true },
        { "name": "outputs", "title": "Outputs", "collapsed": false }
    ]

    contentWidth: availableWidth
    clip: true
    ScrollBar.vertical: MScrollBar {}

    ColumnLayout {
        width: root.availableWidth
        spacing: 0

        Repeater {
            model: root.groups

            ColumnLayout {
                id: group
                Layout.fillWidth: true
                spacing: 0

                readonly property var attributes: {
                    const list = []
                    for (let i = 0; root.node && i < root.node.attributes.count; ++i) {
                        const attribute = root.node.attributes.at(i)
                        if (editor.inGroup(attribute))
                            list.push(attribute)
                    }
                    return list
                }
                readonly property bool collapsed: root.node ? GraphEditorSettings.isGroupCollapsed(root.node.nodeType, modelData.title, modelData.collapsed) : false
                // Attributes the editor can list (disabled ones are hidden); modified count and reset cover them all
                readonly property int shownCount: attributes.filter(a => !a.hasDisplayableShape && (a.enabled || a.hasAnyOutputLinks)).length
                // A search shows the matches of the collapsed groups too
                readonly property bool expanded: !collapsed || root.filterText !== ""

                visible: attributes.length > 0

                // Header
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 4

                    MouseArea {
                        Layout.fillWidth: true
                        implicitHeight: headerRow.implicitHeight
                        cursorShape: Qt.PointingHandCursor
                        onClicked: GraphEditorSettings.setGroupCollapsed(root.node.nodeType, modelData.title, !group.collapsed)

                        RowLayout {
                            id: headerRow
                            spacing: 2
                            MaterialLabel {
                                text: group.expanded ? MaterialIcons.expand_more : MaterialIcons.chevron_right
                                font.pointSize: 10
                                color: GraphTheme.panelTextSecondary
                            }
                            Label {
                                text: modelData.title.toUpperCase() + "  · " + group.shownCount
                                color: GraphTheme.panelTextSecondary
                                font.family: GraphTheme.fontFamily
                                font.pointSize: 8
                                font.bold: true
                                font.letterSpacing: 1
                                padding: 3
                            }
                        }
                    }

                    AttributeModifiedBadge {
                        Layout.rightMargin: 8
                        attributes: group.attributes
                        readOnly: root.readOnly
                    }
                }

                AttributeEditor {
                    id: editor
                    Layout.fillWidth: true
                    visible: group.expanded
                    interactive: false
                    attributeGroup: modelData.name
                    model: root.node ? root.node.attributes : null
                    readOnly: root.readOnly
                    filterText: root.filterText
                    onUpgradeRequest: root.upgradeRequest()
                    onAttributeDoubleClicked: function(mouse, attribute) { root.attributeDoubleClicked(mouse, attribute) }
                    onInAttributeClicked: function(srcItem, mouse, inAttributes) { root.inAttributeClicked(srcItem, mouse, inAttributes) }
                    onOutAttributeClicked: function(srcItem, mouse, outAttributes) { root.outAttributeClicked(srcItem, mouse, outAttributes) }
                    onShowInViewer: function(attribute) { root.showInViewer(attribute) }
                }
            }
        }
    }
}
