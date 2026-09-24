import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Controls 1.0

/**
 * Popup listing the completions provided by a PyCompleter at the text cursor of the script editor.
 * It never takes the keyboard focus: the text area forwards the navigation keys to it.
 */
Popup {
    id: root

    // The PyCompleter providing the completions
    property var completer: null
    readonly property var completions: completer ? completer.completions : []
    // Height the popup never exceeds, whatever the number of completions
    readonly property real maximumHeight: maximumContentHeight + topPadding + bottomPadding
    readonly property real maximumContentHeight: 240

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
    padding: 1
    margins: 0

    background: Rectangle {
        color: palette.window
        border.color: palette.mid
    }

    contentItem: ListView {
        id: listView

        implicitWidth: 320
        implicitHeight: Math.min(contentHeight, root.maximumContentHeight)

        model: root.completions
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        highlightMoveDuration: 0
        ScrollBar.vertical: MScrollBar {}

        // Select the first completion each time the list is updated
        onModelChanged: currentIndex = 0

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
