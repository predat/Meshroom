import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Controls 1.0

/**
 * Popup listing the completions provided by a PyCompleter at the text cursor of the script editor,
 * with the docstring of the selected completion next to the list.
 * It never takes the keyboard focus: the text area forwards the navigation keys to it.
 */
Popup {
    id: root

    // The PyCompleter providing the completions
    property var completer: null
    readonly property var completions: completer ? completer.completions : []
    readonly property string docstring: completer ? completer.docstring : ""
    // Height the popup never exceeds, whatever the number of completions and the docstring length
    readonly property real maximumHeight: maximumContentHeight + 2
    readonly property real maximumContentHeight: 240
    // Whether the popup is displayed above the text cursor: its parts are then aligned on its bottom,
    // so that the list stays next to the cursor whatever the docstring height
    property bool aboveCursor: false

    // Emitted when a completion is chosen, with its {"name", "prefixLength", "type"} description
    signal completionSelected(var completion)

    function moveSelection(offset) {
        if (listView.count === 0)
            return
        listView.currentIndex = Math.max(0, Math.min(listView.count - 1, listView.currentIndex + offset))
    }

    function acceptCurrent() {
        if (listView.currentIndex >= 0 && listView.currentIndex < completions.length)
            completionSelected(completions[listView.currentIndex])
    }

    // Keep the keyboard focus in the text area
    focus: false
    closePolicy: Popup.CloseOnPressOutside
    padding: 0
    margins: 0

    // Each part has its own background, as they do not have the same height
    background: null

    // A Row, and not a RowLayout: the size of each part is given by its own content,
    // and the popup gets its size from the implicit size of the Row (the Row only sets the x of its children)
    contentItem: Row {
        Rectangle {
            width: listView.width + 2
            height: listView.height + 2
            y: root.aboveCursor ? parent.height - height : 0
            color: palette.window
            border.color: palette.mid

            ListView {
                id: listView

                x: 1
                y: 1
                width: 320
                height: Math.min(contentHeight, root.maximumContentHeight)

                model: root.completions
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                highlightMoveDuration: 0
                ScrollBar.vertical: MScrollBar {}

                // Select the first completion each time the list is updated
                onModelChanged: {
                    currentIndex = 0
                    if (root.completer)
                        root.completer.requestDocstring(currentIndex)
                }
                onCurrentIndexChanged: {
                    if (root.completer)
                        root.completer.requestDocstring(currentIndex)
                }

                delegate: ItemDelegate {
                    width: ListView.view.width
                    topPadding: 2
                    bottomPadding: 2
                    highlighted: ListView.isCurrentItem
                    // Keep the keyboard focus in the text area when clicking a completion
                    focusPolicy: Qt.NoFocus

                    contentItem: RowLayout {
                        Label {
                            Layout.fillWidth: true
                            text: modelData.name
                            elide: Text.ElideRight
                        }
                        Label {
                            text: modelData.type
                            opacity: 0.6
                            font.pointSize: 8
                        }
                    }

                    onClicked: root.completionSelected(modelData)
                }
            }
        }

        // Docstring of the selected completion
        Rectangle {
            width: 420
            height: Math.min(docText.implicitHeight, root.maximumContentHeight) + 2
            y: root.aboveCursor ? parent.height - height : 0
            visible: root.docstring !== ""
            color: palette.base
            border.color: palette.mid

            Flickable {
                anchors.fill: parent
                anchors.margins: 1
                contentHeight: docText.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: MScrollBar {}

                Label {
                    id: docText
                    width: parent.width
                    padding: 6
                    text: root.docstring
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    font.pointSize: root.font.pointSize - 1
                }
            }
        }
    }
}
