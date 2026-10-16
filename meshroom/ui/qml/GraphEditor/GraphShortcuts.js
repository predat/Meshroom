.pragma library

/**
 * Single table of the Graph Editor shortcuts: feeds the tooltips, the context menus and the help overlay.
 */

var groups = ["Navigation", "Selection", "Editing", "Edges"]

var shortcuts = [
    { action: "pan", group: "Navigation", keys: "Middle drag / Alt+drag", description: "Pan the graph" },
    { action: "zoom", group: "Navigation", keys: "Wheel", description: "Zoom" },
    { action: "fit", group: "Navigation", keys: "f", description: "Fit the selection, or the whole graph" },
    { action: "help", group: "Navigation", keys: "?", description: "Show this help" },
    { action: "showGrid", group: "Navigation", keys: "Shift+g", description: "Show/Hide grid" },

    { action: "select", group: "Selection", keys: "Click / drag", description: "Select nodes" },
    { action: "addSelect", group: "Selection", keys: "Shift+click / drag", description: "Add to the selection" },
    { action: "toggleSelect", group: "Selection", keys: "Ctrl+click", description: "Toggle in the selection" },
    { action: "selectFollowing", group: "Selection", keys: "Alt+click", description: "Select the following nodes" },

    { action: "newNode", group: "Editing", keys: "Tab / right-click", description: "Create a node" },
    { action: "duplicate", group: "Editing", keys: "d", description: "Duplicate the selected nodes (Alt: from here)" },
    { action: "remove", group: "Editing", keys: "Del", description: "Remove the selected nodes (Alt: from here)" },
    { action: "copy", group: "Editing", keys: "Ctrl+c / Ctrl+x / Ctrl+v", description: "Copy, cut, paste" },
    { action: "color", group: "Editing", keys: "c", description: "Color the selected nodes" },
    { action: "align", group: "Editing", keys: "Shift+V / Shift+H", description: "Align vertically / horizontally" },

    { action: "disconnect", group: "Edges", keys: "x / shake", description: "Disconnect the selected nodes" },
    { action: "removeEdge", group: "Edges", keys: "Alt+click", description: "Remove an edge" },
    { action: "cut", group: "Edges", keys: "k + drag / tap k, drag / Ctrl+Alt+drag", description: "Cut the crossed edges" },
    { action: "insert", group: "Edges", keys: "Drop on edge", description: "Insert a node on an edge (Alt: don't)" },
]

/// Shortcut keys of an action
function keys(action) {
    const shortcut = shortcuts.find(s => s.action === action)
    return shortcut ? shortcut.keys : ""
}

/// "Label — keys" hint of an action, for tooltips and menus
function hint(label, action) {
    return label + " — " + keys(action)
}
