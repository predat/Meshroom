import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

import Controls 1.0
import MaterialIcons 2.2
import Utils 1.0

import Qt.labs.platform as Platform

import ScriptEditor 1.0

Item {
    id: root

    // Defines the parent or the root Application of which this script editor is a part of
    property var rootApplication: undefined;

    Component {
        id: clearConfirmationDialog

        MessageDialog {
            title: "Clear history"

            preset: "Warning"
            text: "This will clear all history of executed scripts."
            helperText: "Are you sure you would like to continue?."

            standardButtons: Dialog.Ok | Dialog.Cancel
            onClosed: destroy()
        }
    }

    function replace(text, string, replacement) {
        /**
         * Replaces all occurrences of the string in the text
         * @param text - overall text
         * @param string - the string to be replaced in the text
         * @param replacement - the replacement of the string
         */
        // Split with the string
        let lines = text.split(string)
        // Return the overall text joined with the replacement
        return lines.join(replacement)
    }

    function formatInput(text) {
        /**
         * Formats the text to be displayed as the input script executed
         */

        // Replace the text to be RichText Supportive
        return "<font color=#868686>> Input:<br>" + replace(text, "\n", "<br>") + "</font><br>"
    }

    function formatOutput(text) {
        /**
         * Formats the text to be displayed as the result of the script executed
         */

        // Replace the text to be RichText Supportive
        return "<font color=#49a1f3>> Result:<br>" + replace(text, "\n", "<br>") + "</font><br>"
    }

    function clearHistory() {
        /**
         * Clears all of the executed history from the script editor
         */
        ScriptEditorManager.clearHistory()
        input.clear()
        output.clear()
    }

    function processScript(text = "") {
        // Use either the provided/selected or the entire script
        text = text || input.text

        // Execute the process and fetch back the return for it
        var ret = ScriptEditorManager.process(text)

        // Append the input script and the output result to the output console
        output.append(formatInput(text) + formatOutput(ret))

        // Save the entire script after executing the commands
        ScriptEditorManager.saveScript(input.text)
        // The execution may have defined new names to complete
        ScriptEditorManager.completer.warmUp(input.text)
    }

    // Whether completions are being displayed or requested for the text under the cursor
    property bool completionActive: false

    function updateCompletion() {
        /**
         * Requests the completions at the text cursor, or stops the completion
         * if the cursor is not right after an identifier or a dot
         */
        if (!/[\w.]/.test(input.text.charAt(input.cursorPosition - 1))) {
            closeCompletion()
            return
        }
        ScriptEditorManager.completer.requestCompletions(input.text, input.cursorPosition)
    }

    function closeCompletion() {
        completionActive = false
        completionPopup.close()
        ScriptEditorManager.completer.clearCompletions()
    }

    function loadScript(fileUrl) {
        var request = new XMLHttpRequest()
        request.open("GET", fileUrl, false)
        request.send(null)
        return request.responseText
    }

    function saveScript(fileUrl, content) {
        var request = new XMLHttpRequest()
        request.open("PUT", fileUrl, false)
        request.send(content)
        return request.status
    }

    implicitWidth: 500
    implicitHeight: 500

    // Parse the script modules in the background, so that the first completion is not delayed
    onVisibleChanged: {
        if (visible)
            ScriptEditorManager.completer.warmUp(input.text)
    }

    Platform.FileDialog {
        id: loadScriptDialog
        title: "Load Script"
        nameFilters: ["Python Script (*.py)"]
        onAccepted: {
            input.clear()
            input.text = loadScript(currentFile)
        }
    }

    Platform.FileDialog {
        id: saveScriptDialog
        title: "Save script"
        nameFilters: ["Python Script (*.py)"]
        fileMode: Platform.FileDialog.SaveFile

        signal closed(var result)

        onAccepted: {
            if (Filepath.extension(currentFile) != ".py")
                currentFile = currentFile + ".py"
            var ret = saveScript(currentFile, input.text)
            if (ret)
                closed(Platform.Dialog.Accepted)
            else
                closed(Platform.Dialog.Rejected)
        }

        onRejected: closed(Platform.Dialog.Rejected)
    }

    ColumnLayout {
        anchors.fill: parent

        RowLayout {
            Layout.alignment: Qt.AlignVCenter | Qt.AlignHCenter

            MaterialToolButton {
                font.pointSize: 13
                text: MaterialIcons.file_open
                ToolTip.text: "Load Script"

                onClicked: {
                    loadScriptDialog.open()
                }
            }

            MaterialToolButton {
                font.pointSize: 13
                text: MaterialIcons.save
                ToolTip.text: "Save Script"

                onClicked: {
                    saveScriptDialog.open()
                }
            }

            MaterialToolButton {
                font.pointSize: 13
                text: MaterialIcons.history
                ToolTip.text: "Get Previous Script"

                enabled: ScriptEditorManager.hasPreviousScript;

                onClicked: {
                    var ret = ScriptEditorManager.getPreviousScript()

                    if (ret != "") {
                        input.clear()
                        input.text = ret
                    }
                }
            }

            MaterialToolButton {
                font.pointSize: 13
                text: MaterialIcons.update
                ToolTip.text: "Get Next Script"

                enabled: ScriptEditorManager.hasNextScript;

                onClicked: {
                    var ret = ScriptEditorManager.getNextScript()

                    if (ret != "") {
                        input.clear()
                        input.text = ret
                    }
                }
            }

            MaterialToolButton {
                font.pointSize: 13
                text: MaterialIcons.delete_sweep
                ToolTip.text: "Clear History"

                onClicked: {
                    // Confirm from the user before clearing out any history
                    const confirmationDialog = clearConfirmationDialog.createObject(rootApplication ? rootApplication : root);
                    confirmationDialog.accepted.connect(clearHistory);
                    confirmationDialog.open();
                }
            }

            Item {
                width: executeButton.width;
            }
            
            MaterialToolButton {
                id: executeButton
                font.pointSize: 13
                text: MaterialIcons.play_arrow
                ToolTip.text: "Execute Script"

                onClicked: {
                    root.processScript()
                }
            }

            Item {
                Layout.fillWidth: true
            }

            MaterialToolButton {
                font.pointSize: 13
                text: MaterialIcons.backspace
                ToolTip.text: "Clear Output Window"

                onClicked: {
                    output.clear()
                }
            }
        }

        MSplitView {
            id: scriptSplitView;
            Layout.fillHeight: true;
            Layout.fillWidth: true;
            orientation: Qt.Horizontal;

            // Input Text Area -- Holds the input scripts to be executed
            Rectangle {
                id: inputArea
                SplitView.preferredWidth: root.width / 2;

                color: palette.base

                ListView {
                    id: lineNumbers
                    property TextMetrics textMetrics: TextMetrics { text: "9999" }
                    model: input.text.split(/\n/g)
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: lineNumbers.textMetrics.boundingRect.width
                    clip: false

                    delegate: Rectangle {
                        width: lineNumbers.width
                        height: lineText.height
                        color: palette.mid
                        Text {
                            id: lineNumber
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: index + 1
                            font.bold: true
                            color: palette.text
                        }

                        Text {
                            id: lineText
                            width: flickableInput.width
                            text: modelData
                            visible: false
                            wrapMode: Text.WordWrap
                        }
                    }

                    onContentYChanged: {
                        if (!moving)
                            return
                        flickableInput.contentY = contentY
                    }
                }

                Flickable {
                    id: flickableInput
                    width: parent.width
                    height: parent.height
                    contentWidth: width
                    contentHeight: input.contentHeight;

                    anchors.left: lineNumbers.right
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom

                    ScrollBar.vertical: MScrollBar {}

                    TextArea.flickable: TextArea {
                        id: input

                        text: ScriptEditorManager.loadLastScript()

                        font: lineNumbers.textMetrics.font
                        Layout.fillHeight: true
                        Layout.fillWidth: true

                        wrapMode: Text.WordWrap
                        selectByMouse: true
                        padding: 0

                        onPressed: {
                            root.forceActiveFocus()
                        }

                        Keys.onPressed: function(event) {
                            if ((event.key === Qt.Key_Enter || event.key === Qt.Key_Return) && event.modifiers === Qt.ControlModifier) {
                                root.processScript(input.selectedText)
                                return
                            }
                            if (!ScriptEditorManager.completer.available)
                                return

                            // Ctrl+Space: complete
                            if (event.key === Qt.Key_Space && event.modifiers === Qt.ControlModifier) {
                                root.completionActive = true
                                root.updateCompletion()
                                event.accepted = true
                                return
                            }

                            // Navigate in and accept the completions while they are displayed
                            if (completionPopup.visible) {
                                switch (event.key) {
                                case Qt.Key_Up:
                                    completionPopup.moveSelection(-1)
                                    event.accepted = true
                                    return
                                case Qt.Key_Down:
                                    completionPopup.moveSelection(1)
                                    event.accepted = true
                                    return
                                case Qt.Key_PageUp:
                                    completionPopup.moveSelection(-10)
                                    event.accepted = true
                                    return
                                case Qt.Key_PageDown:
                                    completionPopup.moveSelection(10)
                                    event.accepted = true
                                    return
                                case Qt.Key_Tab:
                                case Qt.Key_Enter:
                                case Qt.Key_Return:
                                    completionPopup.acceptCurrent()
                                    event.accepted = true
                                    return
                                }
                            }
                            if (event.key === Qt.Key_Escape && root.completionActive) {
                                root.closeCompletion()
                                event.accepted = true
                                return
                            }

                            // Automatic trigger: completions after a dot
                            if (event.text === ".")
                                root.completionActive = true

                            if (event.text !== "" || event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
                                // Update once the typed character has been inserted
                                if (root.completionActive)
                                    Qt.callLater(root.updateCompletion)
                            }
                            else if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down, Qt.Key_Home, Qt.Key_End,
                                      Qt.Key_PageUp, Qt.Key_PageDown].includes(event.key)) {
                                // Moving the cursor ends the completion
                                // (modifier keys alone, such as Shift to type an upper case letter, are ignored)
                                if (root.completionActive)
                                    root.closeCompletion()
                            }
                        }

                        ScriptCompletionPopup {
                            id: completionPopup
                            completer: ScriptEditorManager.completer
                            x: input.cursorRectangle.x
                            // Below the cursor, or above it when there is not enough room in the window.
                            // The side is chosen from the maximum height, so that the popup does not jump
                            // from one side to the other when the number of completions changes.
                            y: {
                                const below = input.cursorRectangle.y + input.cursorRectangle.height
                                if (input.mapToItem(null, 0, below).y + maximumHeight <= input.Window.height)
                                    return below
                                return input.cursorRectangle.y - height
                            }
                            font: input.font

                            onCompletionSelected: function(completion) {
                                // Replace the typed prefix, which may differ in case, with the completed name
                                input.remove(input.cursorPosition - completion.prefixLength, input.cursorPosition)
                                input.insert(input.cursorPosition, completion.name)
                                root.closeCompletion()
                                input.forceActiveFocus()
                            }
                            // Closed by a click outside of the popup
                            onClosed: root.completionActive = false
                        }

                        Connections {
                            target: ScriptEditorManager.completer
                            function onCompletionsChanged() {
                                if (root.completionActive && ScriptEditorManager.completer.completions.length > 0)
                                    completionPopup.open()
                                else
                                    completionPopup.close()
                            }
                        }
                    }

                    onContentYChanged: {
                        if (lineNumbers.moving)
                            return
                        lineNumbers.contentY = contentY
                    }
                }
            }

            // Output Text Area -- Shows the output for the executed script(s)
            Rectangle {
                id: outputArea
                Layout.fillHeight: true
                Layout.fillWidth: true

                color: palette.base

                Flickable {
                    width: parent.width
                    height: parent.height
                    contentWidth: width
                    contentHeight: output.contentHeight;

                    ScrollBar.vertical: MScrollBar {}

                    TextArea.flickable: TextArea {
                        id: output

                        readOnly: true
                        selectByMouse: true
                        padding: 0
                        Layout.fillHeight: true
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap

                        textFormat: Text.RichText
                    }
                }
            }

            // Syntax Highlights for the Input Area for Python Based Syntax
            PySyntaxHighlighter {
                id: syntaxHighlighter
                // The document to highlight
                textDocument: input.textDocument
            }
        }
    }
}