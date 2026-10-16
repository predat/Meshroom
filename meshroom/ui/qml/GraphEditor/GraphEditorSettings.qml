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
