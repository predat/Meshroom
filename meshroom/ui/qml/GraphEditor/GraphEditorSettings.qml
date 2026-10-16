pragma Singleton
import QtCore

/**
 * Persistent Settings related to the GraphEditor module.
 */

Settings {
    category: 'GraphEditor'
    property bool showDefaultAttributes: true
    property bool showModifiedAttributes: true
    property bool showInputAttributes: true
    property bool showOutputAttributes: true
    property bool showLinkAttributes: true
    property bool showNotLinkAttributes: true
    property bool lockOnCompute: true
    // Semantic zoom: below the structure threshold, nodes only show their header; below the overview one, a pill
    property bool semanticZoom: true
    property real lodStructureThreshold: 0.8
    property real lodOverviewThreshold: 0.4
    // Dropping a node (moved or created from the menu) on a compatible edge inserts it
    property bool insertOnEdge: true
    property bool showMinimap: true
    // Command palette recent items, as a JSON list of "node:<type>" / "pipeline:<name>" (most recent first)
    property string paletteRecents: "[]"
    // Collapsed attribute groups of the Node Editor, as a JSON map {nodeType: {group: collapsed}}
    property string inspectorCollapsed: "{}"

    function isGroupCollapsed(nodeType, group, defaultValue) {
        try {
            const state = JSON.parse(inspectorCollapsed)[nodeType]
            return state && group in state ? state[group] : defaultValue
        } catch (e) {
            return defaultValue
        }
    }

    function setGroupCollapsed(nodeType, group, collapsed) {
        let states = {}
        try {
            states = JSON.parse(inspectorCollapsed)
        } catch (e) {}
        states[nodeType] = states[nodeType] || {}
        states[nodeType][group] = collapsed
        inspectorCollapsed = JSON.stringify(states)
    }
}
