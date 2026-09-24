""" Script Editor for Meshroom.
"""
# STD
import ast
import html
import logging
import traceback
from contextlib import redirect_stdout
from io import StringIO
from threading import Condition, Thread

# Qt
from PySide6 import QtCore, QtGui
from PySide6.QtCore import Property, QObject, QSettings, Signal, Slot

try:
    import jedi
except ImportError:
    jedi = None


class PyCompleter(QObject):
    """
    Provides Python completions, docstrings and call signatures for the script editor, using jedi.

    Everything is computed on a worker thread, as a jedi request can take a few seconds.
    Only the latest request is processed: a request that becomes outdated while waiting
    for the worker is skipped, and the results of an outdated request are discarded.
    """

    # Docstrings can be huge (numpy's are up to tens of thousands of characters)
    _MAX_DOCSTRING_LENGTH = 3000

    def __init__(self, namespaceGetter, parent=None):
        """
        Args:
            namespaceGetter (callable): returns the dict of live objects the scripts are executed with,
                                        used by jedi to complete names that cannot be inferred statically.
            parent (QObject): the parent object.
        """
        super().__init__(parent=parent)
        self._namespaceGetter = namespaceGetter
        self._completions = []
        self._signatures = []
        self._docstring = ""
        self._requestId = 0
        # Id of the last request issued when the completions or the signatures were cleared:
        # the results of the requests issued before are discarded
        self._completionsClearId = 0
        self._signaturesClearId = 0
        # Id of the request that produced the current completions, and index of the docstring displayed
        self._completionsRequestId = 0
        self._docstringIndex = -1

        self._condition = Condition()
        self._pendingRequest = None
        self._pendingDocstringRequest = None
        self._thread = None
        # Worker side only: (requestId, jedi completions) of the last request computing completions,
        # used to get the docstrings on demand
        self._workerCompletions = (0, [])

        self._resultsReady.connect(self._onResultsReady, QtCore.Qt.QueuedConnection)
        self._docstringReady.connect(self._onDocstringReady, QtCore.Qt.QueuedConnection)

    @classmethod
    def _truncate(cls, text):
        if len(text) > cls._MAX_DOCSTRING_LENGTH:
            return text[:cls._MAX_DOCSTRING_LENGTH] + "\n[...]"
        return text

    @staticmethod
    def _formatSignature(signature):
        """ Returns the signature as rich text, with the parameter being typed in bold. """
        params = [html.escape(param.to_string()) for param in signature.params]
        if signature.index is not None and 0 <= signature.index < len(params):
            params[signature.index] = f"<b>{params[signature.index]}</b>"
        return f"{html.escape(signature.name)}({', '.join(params)})"

    def _run(self):
        """ Worker loop: process the latest request, then the latest docstring request, and send the results back. """
        while True:
            with self._condition:
                while self._pendingRequest is None and self._pendingDocstringRequest is None:
                    self._condition.wait()
                # Completions and signatures have priority over the docstring of the selected completion
                if self._pendingRequest is not None:
                    request, self._pendingRequest = self._pendingRequest, None
                    docstringRequest = None
                else:
                    docstringRequest, self._pendingDocstringRequest = self._pendingDocstringRequest, None

            try:
                if docstringRequest is not None:
                    self._processDocstringRequest(*docstringRequest)
                else:
                    self._processRequest(*request)
            except Exception:
                # Invalid code or jedi internal error: there is simply nothing to show
                logging.debug("ScriptEditor: completion failed", exc_info=True)

    def _processRequest(self, requestId, positions, namespace, withCompletions, withSignatures):
        completions = []
        signatures = []
        for script, line, column in positions:
            # Give up the remaining positions (of a warm-up) as soon as a new request is waiting
            if self._pendingRequest is not None:
                return
            interpreter = jedi.Interpreter(script, [namespace])
            if withCompletions:
                jediCompletions = interpreter.complete(line, column)
                self._workerCompletions = (requestId, jediCompletions)
                # jedi matches case-insensitively: the typed prefix is replaced by the name when inserting a completion
                completions = [{"name": c.name, "prefixLength": len(c.name) - len(c.complete), "type": c.type}
                               for c in jediCompletions]
            if withSignatures:
                signatures = [{"label": self._formatSignature(sig), "docstring": self._truncate(sig.docstring(raw=True))}
                              for sig in interpreter.get_signatures(line, column)]
        self._resultsReady.emit(requestId, {"completions": completions if withCompletions else None,
                                            "signatures": signatures if withSignatures else None})

    def _processDocstringRequest(self, requestId, index):
        completionsRequestId, jediCompletions = self._workerCompletions
        if completionsRequestId != requestId or not 0 <= index < len(jediCompletions):
            return
        self._docstringReady.emit(requestId, index, self._truncate(jediCompletions[index].docstring()))

    @Slot(int, object)
    def _onResultsReady(self, requestId, results):
        # Discard the results of a request that has been superseded since
        if requestId != self._requestId:
            return
        # Also discard the completions or the signatures cleared since the request was issued
        if results["completions"] is not None and requestId > self._completionsClearId:
            self._completionsRequestId = requestId
            self._completions = results["completions"]
            self._setDocstring(-1, "")
            self.completionsChanged.emit()
        if results["signatures"] is not None and requestId > self._signaturesClearId:
            self._signatures = results["signatures"]
            self.signaturesChanged.emit()

    @Slot(int, int, str)
    def _onDocstringReady(self, requestId, index, docstring):
        # Discard the docstring if the completions or the selected one have changed since
        if requestId == self._completionsRequestId and index == self._docstringIndex:
            self._setDocstring(index, docstring)

    def _setDocstring(self, index, docstring):
        self._docstringIndex = index
        if docstring != self._docstring:
            self._docstring = docstring
            self.docstringChanged.emit()

    def _submit(self, requestId, positions, withCompletions=True, withSignatures=False):
        """
        Hand a request over to the worker thread, replacing any request not started yet.

        Args:
            requestId (int): the id of the request, compared to the current one when its results are ready.
            positions (list): the (script, cursorPosition) pairs to process; the results are the ones of the last pair.
            withCompletions (bool): whether to compute the completions.
            withSignatures (bool): whether to compute the signatures of the call being typed.
        """
        if not self.available or not positions:
            return
        if self._thread is None:
            self._thread = Thread(target=self._run, daemon=True)
            self._thread.start()

        jediPositions = []
        for script, cursorPosition in positions:
            # jedi expects a 1-based line and a 0-based column
            before = script[:cursorPosition]
            line = before.count("\n") + 1
            column = len(before) - (before.rfind("\n") + 1)
            jediPositions.append((script, line, column))

        with self._condition:
            # Copy the namespace so that the worker is not affected by a script executed meanwhile
            self._pendingRequest = (requestId, jediPositions, dict(self._namespaceGetter()), withCompletions, withSignatures)
            self._condition.notify()

    @Slot(str, int, bool, bool)
    def request(self, script, cursorPosition, completions, signatures):
        """
        Asynchronously compute the completions and/or the signatures at the given position of the script.
        The "completions" and "signatures" properties are updated once they are available.

        Args:
            script (str): the whole script.
            cursorPosition (int): the position of the text cursor in the script.
            completions (bool): whether to compute the completions.
            signatures (bool): whether to compute the signatures of the call being typed.
        """
        self._requestId += 1
        self._submit(self._requestId, [(script, cursorPosition)], completions, signatures)

    @Slot(str, int)
    def requestCompletions(self, script, cursorPosition):
        """ Asynchronously compute the completions at the given position of the script. """
        self.request(script, cursorPosition, True, False)

    @Slot(int)
    def requestDocstring(self, index):
        """
        Asynchronously get the docstring of a completion.
        The "docstring" property is updated once it is available.

        Args:
            index (int): the index of the completion in the "completions" list.
        """
        if not 0 <= index < len(self._completions):
            self._setDocstring(-1, "")
            return
        self._docstringIndex = index
        with self._condition:
            self._pendingDocstringRequest = (self._completionsRequestId, index)
            self._condition.notify()

    @Slot(str)
    def warmUp(self, script):
        """
        Complete the attributes of the top-level names of the script in the background, discarding the results.
        The first completion on an object can take a few seconds, as jedi parses the modules it comes from:
        warming up makes the completions on the script variables immediate afterwards.
        A completion request interrupts the warm-up.

        Args:
            script (str): the script to warm up the completion with.
        """
        try:
            tree = ast.parse(script)
        except SyntaxError:
            return
        names = []
        for node in ast.walk(tree):
            # Assigned variables, loop variables, imported names and so on
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
                names.append(node.id)
            elif isinstance(node, ast.alias):
                names.append((node.asname or node.name).split(".")[0])
        # Complete "<name>." on a new line at the end of the script, for each name
        positions = []
        for name in dict.fromkeys(names):
            warmUpScript = f"{script}\n{name}."
            positions.append((warmUpScript, len(warmUpScript)))
        # A negative request id is never the current one: the results are discarded
        self._submit(-1, positions)

    @Slot()
    def clearCompletions(self):
        """ Clear the completions and discard the completions of any pending request. """
        self._completionsClearId = self._requestId
        self._setDocstring(-1, "")
        if self._completions:
            self._completions = []
            self.completionsChanged.emit()

    @Slot()
    def clearSignatures(self):
        """ Clear the signatures and discard the signatures of any pending request. """
        self._signaturesClearId = self._requestId
        if self._signatures:
            self._signatures = []
            self.signaturesChanged.emit()

    _resultsReady = Signal(int, object)
    _docstringReady = Signal(int, int, str)
    completionsChanged = Signal()
    signaturesChanged = Signal()
    docstringChanged = Signal()
    # List of {"name", "prefixLength", "type"} dicts, "prefixLength" being the length of the text before the cursor
    # that the name replaces
    completions = Property("QVariantList", lambda self: self._completions, notify=completionsChanged)
    # List of {"label", "docstring"} dicts for the call being typed, "label" being rich text
    # with the current parameter in bold
    signatures = Property("QVariantList", lambda self: self._signatures, notify=signaturesChanged)
    # Docstring of the completion requested with requestDocstring
    docstring = Property(str, lambda self: self._docstring, notify=docstringChanged)
    available = Property(bool, lambda self: jedi is not None, constant=True)


class ScriptEditorManager(QObject):
    """ Manages the script editor history and logs. """

    _GROUP = "ScriptEditor"
    _KEY = "script"

    def __init__(self, parent=None):
        super(ScriptEditorManager, self).__init__(parent=parent)
        self._history = []
        self._index = -1

        self._globals = {}
        self._locals = {}

        self._completer = PyCompleter(self._completionNamespace, parent=self)
        if jedi is None:
            logging.info("ScriptEditor: jedi is not available, code completion is disabled.")

    # Protected
    def _defaultScript(self):
        """ Returns the default script for the script editor. """
        lines = (
            "from meshroom.ui import uiInstance\n",
            "graph = uiInstance.activeProject.graph",
            "for node in graph.nodes:",
            "    print(node.name)"
        )

        return "\n".join(lines)

    def _lastScript(self):
        """ Returns the last script from the user settings. """
        settings = QSettings()
        settings.beginGroup(self._GROUP)
        return settings.value(self._KEY)

    def _completionNamespace(self):
        """ Returns the live objects available to the scripts, for the completion. """
        # Import within the method to prevent cyclic dependencies
        from meshroom import ui
        # uiInstance is only set at runtime by meshroom.ui.__main__: provide the live instance,
        # as jedi cannot infer it from the "from meshroom.ui import uiInstance" statement of the default script
        namespace = {}
        uiInstance = getattr(ui, "uiInstance", None)
        if uiInstance is not None:
            namespace["uiInstance"] = uiInstance
        namespace.update(self._globals)
        namespace.update(self._locals)
        return namespace

    def _hasPreviousScript(self):
        """ Returns whether there is a previous script available.
        """
        # If the current index is greater than the first
        return self._index > 0

    def _hasNextScript(self):
        """ Returns whether there is a new script available to load. """
        # If the current index is lower than the available indexes
        return self._index < (len(self._history) - 1)

    # Public
    @Slot(str, result=str)
    def process(self, script):
        """ Execute the provided input script, capture the output from the standard output, and return it. """
        # Saves the state if an exception has occurred
        exception = False

        stdout = StringIO()
        with redirect_stdout(stdout):
            try:
                exec(script, self._globals, self._locals)
            except Exception:
                # Update that we have an exception that is thrown
                exception = True
                # Print the backtrace
                traceback.print_exc(file=stdout)

        result = stdout.getvalue().strip()

        # Strip out additional part
        if exception:
            # We know that we are executing the above statement and that caused the exception
            # What we want to show to the user is just the part that happened while executing the script
            # So just split with the last part and show it to the user
            result = result.split("self._locals)", 1)[-1]

        # Add the script to the history and move up the index to the top of history stack
        self._history.append(script)
        self._index = len(self._history)
        self.scriptIndexChanged.emit()

        return result

    @Slot()
    def clearHistory(self):
        """ Clear the list of executed scripts and reset the index. """
        self._history = []
        self._index = -1

    @Slot(result=str)
    def getNextScript(self):
        """
        Get the next entry in the history of executed scripts and update the index adequately.
        If there is no next entry, return an empty string.
        """
        if self._index + 1 < len(self._history) and len(self._history) > 0:
            self._index = self._index + 1
            self.scriptIndexChanged.emit()
            return self._history[self._index]
        return ""

    @Slot(result=str)
    def getPreviousScript(self):
        """
        Get the previous entry in the history of executed scripts and update the index adequately.
        If there is no previous entry, return an empty string.
        """
        if self._index - 1 >= 0 and self._index - 1 < len(self._history):
            self._index = self._index - 1
            self.scriptIndexChanged.emit()
            return self._history[self._index]
        elif self._index == 0 and len(self._history):
            return self._history[self._index]
        return ""

    @Slot(result=str)
    def loadLastScript(self):
        """ Returns the last executed script from the prefs. """
        return self._lastScript() or self._defaultScript()

    @Slot(str)
    def saveScript(self, script):
        """
        Returns the last executed script from the prefs.

        Args:
            script (str): The script to save.
        """
        settings = QSettings()
        settings.beginGroup(self._GROUP)
        settings.setValue(self._KEY, script)
        settings.sync()

    scriptIndexChanged = Signal()

    hasPreviousScript = Property(bool, _hasPreviousScript, notify=scriptIndexChanged)
    hasNextScript = Property(bool, _hasNextScript, notify=scriptIndexChanged)
    completer = Property(QObject, lambda self: self._completer, constant=True)


class CharFormat(QtGui.QTextCharFormat):
    """ The Char format for the syntax.
    """

    def __init__(self, color, bold=False, italic=False):
        """ Constructor.
        """
        super().__init__()

        self._color = QtGui.QColor()
        self._color.setNamedColor(color)

        # Update the Foreground color
        self.setForeground(self._color)

        # The font characteristics
        if bold:
            self.setFontWeight(QtGui.QFont.Bold)
        if italic:
            self.setFontItalic(True)


class PySyntaxHighlighter(QtGui.QSyntaxHighlighter):
    """ Syntax highlighter for the Python language. """

    # Syntax styles that can be shared by all languages
    STYLES = {
        "keyword": CharFormat("#9e59b3"),  # Purple
        "operator": CharFormat("#2cb8a0"),  # Teal
        "brace": CharFormat("#2f807e"),  # Dark Aqua
        "defclass": CharFormat("#c9ba49", bold=True),  # Yellow
        "deffunc": CharFormat("#4996c9", bold=True),  # Blue
        "string": CharFormat("#7dbd39"),  # Greeny
        "comment": CharFormat("#8d8d8d", italic=True),  # Dark Grayish
        "self": CharFormat("#e6ba43", italic=True),  # Yellow
        "numbers": CharFormat("#d47713"),  # Orangish
    }

    # Python keywords
    keywords = (
        "and", "assert", "break", "class", "continue", "def",
        "del", "elif", "else", "except", "exec", "finally",
        "for", "from", "global", "if", "import", "in",
        "is", "lambda", "not", "or", "pass", "print",
        "raise", "return", "try", "while", "yield",
        "None", "True", "False",
    )

    # Python operators
    operators = (
        "=",
        # Comparison
        "==", "!=", "<", "<=", ">", ">=",
        # Arithmetic
        r"\+", "-", r"\*", "/", "//", r"\%", r"\*\*",
        # In-place
        r"\+=", "-=", r"\*=", "/=", r"\%=",
        # Bitwise
        r"\^", r"\|", r"\&", r"\~", r">>", r"<<",
    )

    # Python braces
    braces = (r"\{", r"\}", r"\(", r"\)", r"\[", r"\]")

    def __init__(self, parent=None):
        """
        Constructor.

        Keyword Args:
            parent (QObject): The QObject parent from the QML side.
        """
        super().__init__(parent)

        # The Document to highlight
        self._document = None

        # Build a QRegularExpression for each of the pattern
        self._rules = self.__rules()

    # Private
    def __rules(self):
        """ Formatting rules. """
        # Set of rules accordind to which the highlight should occur
        rules = []

        # Keyword rules
        rules += [(QtCore.QRegularExpression(r"\b" + w + r"\s"), 0,
                   PySyntaxHighlighter.STYLES["keyword"]) for w in PySyntaxHighlighter.keywords]
        # Operator rules
        rules += [(QtCore.QRegularExpression(o), 0,
                   PySyntaxHighlighter.STYLES["operator"]) for o in PySyntaxHighlighter.operators]
        # Braces
        rules += [(QtCore.QRegularExpression(b), 0,
                   PySyntaxHighlighter.STYLES["brace"]) for b in PySyntaxHighlighter.braces]

        # All other rules
        rules += [
            # self
            (QtCore.QRegularExpression(r'\bself\b'), 0, PySyntaxHighlighter.STYLES["self"]),

            # 'def' followed by an identifier
            (QtCore.QRegularExpression(r'\bdef\b\s*(\w+)'), 1, PySyntaxHighlighter.STYLES["deffunc"]),
            # 'class' followed by an identifier
            (QtCore.QRegularExpression(r'\bclass\b\s*(\w+)'), 1, PySyntaxHighlighter.STYLES["defclass"]),

            # Numeric literals
            (QtCore.QRegularExpression(r'\b[+-]?[0-9]+[lL]?\b'), 0, PySyntaxHighlighter.STYLES["numbers"]),
            (QtCore.QRegularExpression(r'\b[+-]?0[xX][0-9A-Fa-f]+[lL]?\b'), 0, PySyntaxHighlighter.STYLES["numbers"]),
            (QtCore.QRegularExpression(r'\b[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\b'), 0,
             PySyntaxHighlighter.STYLES["numbers"]),

            # Double-quoted string, possibly containing escape sequences
            (QtCore.QRegularExpression(r'"[^"\\]*(\\.[^"\\]*)*"'), 0, PySyntaxHighlighter.STYLES["string"]),
            # Single-quoted string, possibly containing escape sequences
            (QtCore.QRegularExpression(r"'[^'\\]*(\\.[^'\\]*)*'"), 0, PySyntaxHighlighter.STYLES["string"]),

            # From '#' until a newline
            (QtCore.QRegularExpression(r'#[^\n]*'), 0, PySyntaxHighlighter.STYLES['comment']),
        ]

        return rules

    def highlightBlock(self, text):
        """
        Applies syntax highlighting to the given block of text.

        Args:
            text (str): The text to highlight.
        """
        # Do other syntax formatting
        for expression, nth, _format in self._rules:
            # fetch the index of the expression in text
            match = expression.match(text, 0)
            index = match.capturedStart()

            while index >= 0:
                # We actually want the index of the nth match
                index = match.capturedStart(nth)
                length = len(match.captured(nth))
                self.setFormat(index, length, _format)
                # index = expression.indexIn(text, index + length)
                match = expression.match(text, index + length)
                index = match.capturedStart()

    def textDoc(self):
        """ Returns the document being highlighted. """
        return self._document

    def setTextDocument(self, document):
        """
        Sets the document on the Highlighter.

        Args:
            document (QtQuick.QQuickTextDocument): The document from the QML engine.
        """
        # If the same document is provided again
        if document == self._document:
            return

        # Update the class document
        self._document = document

        # Set the document on the highlighter
        self.setDocument(self._document.textDocument())

        # Emit that the document is now changed
        self.textDocumentChanged.emit()

    # Signals
    textDocumentChanged = Signal()

    # Property
    textDocument = Property(QObject, textDoc, setTextDocument, notify=textDocumentChanged)
