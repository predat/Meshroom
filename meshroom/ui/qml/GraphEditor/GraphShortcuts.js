.pragma library

/**
 * Single table of the Graph Editor shortcuts: feeds the tooltips, the context menus and the help overlay.
 */

var groups = ["Navigation", "Selection", "Editing", "Edges"]

var shortcuts = [
    { action: "pan", group: "Navigation", keys: "Middle drag / Alt+drag", description: "Pan the graph" },
    { action: "zoom", group: "Navigation", keys: "Wheel", description: "Zoom" },
    { action: "fit", group: "Navigation", keys: "F", description: "Fit the selection, or the whole graph", command: "Fit View" },
    { action: "help", group: "Navigation", keys: "?", description: "Show this help", command: "Show Shortcuts" },

    { action: "select", group: "Selection", keys: "Click / drag", description: "Select nodes" },
    { action: "addSelect", group: "Selection", keys: "Shift+click / drag", description: "Add to the selection" },
    { action: "toggleSelect", group: "Selection", keys: "Ctrl+click", description: "Toggle in the selection" },
    { action: "selectFollowing", group: "Selection", keys: "Alt+click", description: "Select the following nodes" },

    { action: "newNode", group: "Editing", keys: "Tab / Ctrl+K / right-click", description: "Create a node, run a command" },
    { action: "duplicate", group: "Editing", keys: "D", description: "Duplicate the selected nodes (Alt: from here)", command: "Duplicate Selected Nodes" },
    { action: "remove", group: "Editing", keys: "Del", description: "Remove the selected nodes (Alt: from here)", command: "Remove Selected Nodes" },
    { action: "copy", group: "Editing", keys: "Ctrl+C / Ctrl+X / Ctrl+V", description: "Copy, cut, paste" },
    { action: "color", group: "Editing", keys: "C", description: "Color the selected nodes" },
    { action: "align", group: "Editing", keys: "Shift+V / Shift+H", description: "Align vertically / horizontally" },

    { action: "disconnect", group: "Edges", keys: "X / shake", description: "Disconnect the selected nodes", command: "Disconnect Selected Nodes" },
    { action: "removeEdge", group: "Edges", keys: "Alt+click", description: "Remove an edge" },
    { action: "cut", group: "Edges", keys: "K + drag / tap K, drag / Ctrl+Alt+drag", description: "Cut the crossed edges" },
    { action: "insert", group: "Edges", keys: "Drop on edge", description: "Insert a node on an edge (Alt: don't)" },

    // Command palette only (not a group of the help overlay)
    { action: "autoLayout", group: "Commands", keys: "", description: "Lay out the whole graph", command: "Auto-Layout" },
    { action: "selectErrors", group: "Commands", keys: "", description: "Select the nodes in error and fit them", command: "Select Nodes in Error" },
    { action: "compute", group: "Commands", keys: "", description: "Compute the selected nodes", command: "Compute Selected Nodes" },
    { action: "submit", group: "Commands", keys: "", description: "Submit the selected nodes to the render farm", command: "Submit Selected Nodes" },
    { action: "addBackdrop", group: "Commands", keys: "", description: "Add a backdrop around the selected nodes", command: "Add Backdrop" },
    { action: "alignVertically", group: "Commands", keys: "Shift+V", description: "Align the selected nodes vertically", command: "Align Vertically" },
    { action: "alignHorizontally", group: "Commands", keys: "Shift+H", description: "Align the selected nodes horizontally", command: "Align Horizontally" },
    { action: "minimap", group: "Commands", keys: "", description: "Show or hide the minimap", command: "Toggle Minimap" },
    { action: "zoomReset", group: "Commands", keys: "", description: "Zoom at 100 % on the center of the view", command: "Zoom 100 %" },
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
