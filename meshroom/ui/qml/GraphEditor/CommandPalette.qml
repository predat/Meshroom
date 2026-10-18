import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import MaterialIcons 2.2
import Meshroom.Helpers 1.0
import Utils 1.0

import "GraphShortcuts.js" as GraphShortcuts

/**
 * Command palette: fuzzy search over the node types, the pipeline templates, the nodes of the graph
 * and the Graph Editor commands (GraphShortcuts entries with a "command" label).
 * With an empty query: recent items, then the node types by category, then the pipelines.
 * In create mode (right-click on the graph), only the node types and the pipelines are listed.
 */

Popup {
    id: root

    property var nodeTypes: ({})  /// Node types: {type: {category, versionType, doc, inputs}} (_nodeTypes)
    property var pipelines: []  /// Pipeline template names
    property var graphNodes: null  /// Nodes of the graph (model with count/at())
    property bool createMode: false

    signal nodeTypeChosen(string nodeType)
    signal pipelineChosen(string name)
    signal graphNodeChosen(var node)
    signal commandChosen(string action)

    readonly property int maxRecents: 8
    readonly property int rowHeight: 28
    // Maximum number of results by section, for a non-empty query
    readonly property var sectionLimits: { "Nodes": 10, "Pipelines": 5, "In Graph": 5, "Commands": 5 }

    // Searchable items, built when the palette opens: {kind, key, name, label, section, ...}
    property var candidates: []
    property var labels: []
    property var indexByKey: ({})
    property var recentKeys: []
    readonly property var currentCandidate: list.currentIndex >= 0 && list.currentIndex < resultsModel.count
                                            ? candidates[resultsModel.get(list.currentIndex).candidate] || null : null

    width: 440
    // Stay within the Graph Editor: the list shrinks
    height: parent ? Math.min(implicitHeight, parent.height - y - 8) : implicitHeight
    padding: 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    function openPalette(create) {
        createMode = create
        open()
    }

    onAboutToShow: {
        try {
            recentKeys = JSON.parse(GraphEditorSettings.paletteRecents)
        } catch (e) {
            recentKeys = []
        }
        buildCandidates()
        field.text = ""
        refresh()
    }

    onOpened: field.forceActiveFocus()

    function badge(versionType) {
        if (versionType === NodeVersionType.BETA)
            return "beta"
        if (versionType === NodeVersionType.USER)
            return "plugin"
        return ""
    }

    function buildCandidates() {
        const items = []
        for (const [name, info] of Object.entries(nodeTypes)) {
            const style = GraphTheme.categoryStyle(info.category)
            items.push({ "kind": "node", "key": "node:" + name, "name": name, "label": name, "section": "Nodes",
                         "category": info.category, "icon": style.icon, "color": GraphTheme.tokenColor(style.color),
                         "hint": badge(info.versionType), "doc": info.doc, "inputs": info.inputs })
        }
        for (const name of pipelines) {
            items.push({ "kind": "pipeline", "key": "pipeline:" + name, "name": name, "label": name, "section": "Pipelines",
                         "icon": "account_tree", "color": GraphTheme.nodeTextSecondary, "hint": "",
                         "doc": "Import this pipeline template at the cursor." })
        }
        if (!createMode) {
            for (let i = 0; graphNodes && i < graphNodes.count; ++i) {
                const node = graphNodes.at(i)
                items.push({ "kind": "graph", "key": "graph:" + node.name, "node": node, "label": node.label, "section": "In Graph",
                             "icon": "lens", "color": GraphTheme.nodeStatusColors[node.globalStatus] || GraphTheme.nodeTextSecondary,
                             "hint": "", "doc": node.nodeType + " · " + node.globalStatus.toLowerCase() + " — select and center" })
            }
            for (const shortcut of GraphShortcuts.shortcuts.filter(s => s.command)) {
                items.push({ "kind": "command", "key": "command:" + shortcut.action, "name": shortcut.action, "label": shortcut.command,
                             "section": "Commands", "icon": "bolt", "color": GraphTheme.nodeTextSecondary,
                             "hint": shortcut.keys, "doc": shortcut.description })
            }
        }
        const byKey = {}
        items.forEach((item, index) => byKey[item.key] = index)
        candidates = items
        labels = items.map(item => item.label)
        indexByKey = byKey
    }

    /// Label as styled text, with the matched characters in the selection color
    function highlight(label, matches) {
        const escape = c => c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : c
        const matched = new Set(matches)
        let html = ""
        let open = false
        for (let i = 0; i < label.length; ++i) {
            if (matched.has(i) !== open) {
                html += open ? "</font>" : "<font color=\"" + GraphTheme.nodeSelection + "\">"
                open = !open
            }
            html += escape(label[i])
        }
        return open ? html + "</font>" : html
    }

    function refresh() {
        const rows = []
        const row = (index, section, matches) => ({ "candidate": index, "section": section,
                                                    "html": highlight(candidates[index].label, matches) })
        const query = field.text.trim()
        if (query === "") {
            for (const key of recentKeys) {
                if (key in indexByKey)
                    rows.push(row(indexByKey[key], "Recent", []))
            }
            // Node types by category, then pipelines (the former node creation menu)
            const byCategory = {}
            candidates.forEach((item, index) => {
                if (item.kind === "node")
                    (byCategory[item.category] = byCategory[item.category] || []).push(index)
            })
            for (const category of Object.keys(byCategory).sort())
                byCategory[category].forEach(index => rows.push(row(index, category, [])))
            candidates.forEach((item, index) => {
                if (item.kind === "pipeline")
                    rows.push(row(index, "Pipelines", []))
            })
        } else {
            const boosted = recentKeys.filter(key => key in indexByKey).map(key => indexByKey[key])
            // Sections in the order of their best match
            const bySection = new Map()
            for (const result of FuzzyMatcher.search(query, labels, boosted, 0)) {
                const section = candidates[result.index].section
                if (!bySection.has(section))
                    bySection.set(section, [])
                const sectionRows = bySection.get(section)
                if (sectionRows.length < sectionLimits[section])
                    sectionRows.push(row(result.index, section, result.matches))
            }
            for (const sectionRows of bySection.values())
                rows.push(...sectionRows)
        }
        // Update the rows in place: the delegates are reused instead of being recreated at each key
        rows.forEach((r, i) => i < resultsModel.count ? resultsModel.set(i, r) : resultsModel.append(r))
        if (resultsModel.count > rows.length)
            resultsModel.remove(rows.length, resultsModel.count - rows.length)
        list.currentIndex = rows.length > 0 ? 0 : -1
        list.positionViewAtBeginning()
    }

    function execute(index) {
        if (index < 0 || index >= resultsModel.count)
            return
        const item = candidates[resultsModel.get(index).candidate]
        if (item.kind === "node" || item.kind === "pipeline") {
            const recents = [item.key].concat(recentKeys.filter(key => key !== item.key)).slice(0, maxRecents)
            GraphEditorSettings.paletteRecents = JSON.stringify(recents)
        }
        close()
        if (item.kind === "node")
            nodeTypeChosen(item.name)
        else if (item.kind === "pipeline")
            pipelineChosen(item.name)
        else if (item.kind === "graph")
            graphNodeChosen(item.node)
        else
            commandChosen(item.name)
    }

    ListModel { id: resultsModel }

    background: Rectangle {
        color: GraphTheme.nodeBackground
        border.color: GraphTheme.nodeBorder
        radius: 8
    }

    contentItem: ColumnLayout {
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 6
            Layout.leftMargin: 10
            spacing: 6

            MaterialLabel {
                text: MaterialIcons.search
                color: GraphTheme.nodeTextSecondary
                font.pointSize: 11
            }

            TextField {
                id: field
                Layout.fillWidth: true
                placeholderText: root.createMode ? "Create a node or import a pipeline…" : "Search nodes, pipelines, commands…"
                color: GraphTheme.nodeText
                placeholderTextColor: GraphTheme.nodeTextSecondary
                font.family: GraphTheme.fontFamily
                font.pointSize: 10
                background: null
                selectByMouse: true

                onTextChanged: root.refresh()
                Keys.onUpPressed: list.decrementCurrentIndex()
                Keys.onDownPressed: list.incrementCurrentIndex()
                Keys.onReturnPressed: root.execute(list.currentIndex)
                Keys.onEnterPressed: root.execute(list.currentIndex)
                // Tab toggles the palette: it never validates the item under the cursor
                Keys.onTabPressed: function(event) {
                    if (!event.isAutoRepeat)
                        root.close()
                }
                Keys.onEscapePressed: root.close()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: GraphTheme.nodeBorder
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 12 * root.rowHeight)
            Layout.fillHeight: true
            Layout.minimumHeight: root.rowHeight
            clip: true
            model: resultsModel
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

            section.property: "section"
            section.delegate: Label {
                required property string section
                width: ListView.view.width
                topPadding: 8
                bottomPadding: 2
                leftPadding: 10
                text: section.toUpperCase()
                color: GraphTheme.nodeTextSecondary
                font.family: GraphTheme.fontFamily
                font.pointSize: 8
                font.letterSpacing: 1
            }

            delegate: Rectangle {
                id: rowItem
                required property int index
                required property int candidate
                required property string html
                // Delegates of cleared rows are destroyed later: they may still see a newer, shorter candidate list
                readonly property var item: root.candidates[candidate] || { "color": "transparent", "icon": "", "hint": "" }

                width: ListView.view.width
                height: root.rowHeight
                color: ListView.isCurrentItem ? Qt.alpha(GraphTheme.nodeSelection, 0.18) : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 8

                    Rectangle {
                        Layout.preferredWidth: 16
                        Layout.preferredHeight: 16
                        radius: 4
                        color: Qt.alpha(rowItem.item.color, 0.22)

                        MaterialLabel {
                            anchors.centerIn: parent
                            text: MaterialIcons[rowItem.item.icon] || ""
                            color: rowItem.item.color
                            font.pointSize: 8
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: rowItem.html
                        textFormat: Text.StyledText
                        color: GraphTheme.nodeText
                        font.family: GraphTheme.fontFamily
                        font.pointSize: 9
                        elide: Text.ElideRight
                    }

                    Text {
                        text: rowItem.item.hint
                        visible: text !== ""
                        color: GraphTheme.nodeTextSecondary
                        font.family: GraphTheme.monoFamily
                        font.pointSize: 8
                    }
                }
            }

            // Hovering changes the current item without taking the focus from the field. Only real mouse moves count:
            // hover events re-sent while the list changes under a still cursor would steal the keyboard selection.
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                property point lastPosition: Qt.point(-1, -1)

                function indexAt(mouse) {
                    return list.indexAt(mouse.x + list.contentX, mouse.y + list.contentY)
                }

                onPositionChanged: function(mouse) {
                    const position = mapToGlobal(mouse.x, mouse.y)
                    if (position.x === lastPosition.x && position.y === lastPosition.y)
                        return
                    lastPosition = position
                    const index = indexAt(mouse)
                    if (index >= 0)
                        list.currentIndex = index
                }
                onClicked: function(mouse) { root.execute(indexAt(mouse)) }
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.margins: 10
            visible: resultsModel.count === 0
            text: "No match"
            color: GraphTheme.nodeTextSecondary
            font.family: GraphTheme.fontFamily
            font.pointSize: 9
        }

        // Documentation of the current item
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: GraphTheme.nodeBorder
            visible: doc.visible
        }

        ColumnLayout {
            id: doc
            Layout.fillWidth: true
            Layout.margins: 10
            spacing: 6
            visible: root.currentCandidate !== null && root.currentCandidate.doc !== ""

            Label {
                Layout.fillWidth: true
                text: root.currentCandidate ? root.currentCandidate.doc : ""
                color: GraphTheme.nodeTextSecondary
                font.family: GraphTheme.fontFamily
                font.pointSize: 9
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            // Main inputs of a node type, with their data type color
            Flow {
                Layout.fillWidth: true
                spacing: 10
                visible: inputsRepeater.count > 0

                Repeater {
                    id: inputsRepeater
                    model: root.currentCandidate && root.currentCandidate.inputs ? root.currentCandidate.inputs : []

                    Row {
                        spacing: 4
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8
                            height: 8
                            radius: 4
                            color: GraphTheme.dataTypeColor(modelData.dataType)
                        }
                        Label {
                            text: modelData.label
                            color: GraphTheme.nodeText
                            font.family: GraphTheme.fontFamily
                            font.pointSize: 8
                        }
                    }
                }
            }
        }
    }
}
