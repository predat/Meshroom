import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * Popup showing the signatures provided by a PyCompleter for the call being typed in the script editor,
 * with the parameter being typed in bold, and the docstring of the called function.
 * It never takes the keyboard focus.
 */
Popup {
    id: root

    // The PyCompleter providing the signatures
    property var completer: null
    readonly property var signatures: completer ? completer.signatures : []

    focus: false
    closePolicy: Popup.CloseOnPressOutside
    padding: 6
    margins: 0
    width: Math.min(Math.max(content.implicitWidth, 200), 600) + leftPadding + rightPadding

    background: Rectangle {
        color: palette.window
        border.color: palette.mid
    }

    contentItem: ColumnLayout {
        id: content
        spacing: 4

        Repeater {
            model: root.signatures
            Label {
                Layout.fillWidth: true
                // Rich text built and escaped on the Python side, the current parameter being in bold
                text: modelData.label
                textFormat: Text.StyledText
                wrapMode: Text.Wrap
            }
        }

        Label {
            Layout.fillWidth: true
            // The docstring of the first signature: the others are overloads of the same function
            text: root.signatures.length > 0 ? root.signatures[0].docstring : ""
            visible: text !== ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            maximumLineCount: 8
            elide: Text.ElideRight
            opacity: 0.7
            font.pointSize: root.font.pointSize - 1
        }
    }
}
