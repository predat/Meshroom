pragma Singleton
import QtCore

/**
 * Persistent Settings related to the GraphEditor module.
 */

Settings {
    category: 'GraphEditor'
    property bool showAdvancedAttributes: false
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
}
