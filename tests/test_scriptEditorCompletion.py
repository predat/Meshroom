import pytest

pytest.importorskip("jedi")

from PySide6.QtCore import QCoreApplication, QElapsedTimer

from meshroom.ui.components.scriptEditor import ScriptEditorManager


@pytest.fixture(scope="module")
def manager():
    app = QCoreApplication.instance() or QCoreApplication([])  # noqa: F841 - needed by the queued signals
    return ScriptEditorManager()


def waitForSignal(signal, timeout=10000):
    """ Process the events until the signal is emitted or the timeout is reached. Return whether it was emitted. """
    emitted = []
    signal.connect(lambda: emitted.append(True))
    timer = QElapsedTimer()
    timer.start()
    while not emitted and timer.elapsed() < timeout:
        QCoreApplication.processEvents()
    signal.disconnect()
    return bool(emitted)


def waitForCompletions(completer, timeout=10000):
    """ Process the events until the completions are updated or the timeout is reached, and return their names. """
    waitForSignal(completer.completionsChanged, timeout)
    return [c["name"] for c in completer.completions]


def test_completeLiveNamespace(manager):
    manager.process("from meshroom.core.graph import Graph\ng = Graph('test')")
    script = "g.addN"
    manager.completer.request(script, len(script), True, False)
    assert waitForCompletions(manager.completer) == ["addNewNode", "addNode"]


def test_completeMultiline(manager):
    script = "for i in range(3):\n    i.bit_l"
    manager.completer.request(script, len(script), True, False)
    names = waitForCompletions(manager.completer)
    assert names == ["bit_length"]
    assert manager.completer.completions[0]["prefixLength"] == len("bit_l")


def test_completeCaseInsensitive(manager):
    # The whole typed prefix is replaced, to fix its case
    script = "g.addnewn"
    manager.completer.request(script, len(script), True, False)
    assert waitForCompletions(manager.completer) == ["addNewNode"]
    assert manager.completer.completions[0]["prefixLength"] == len("addnewn")


def test_completeAtCursorPosition(manager):
    # Only the text before the cursor is completed
    script = "import os\nos.pa\nprint('end')"
    manager.completer.request(script, script.index("\nprint"), True, False)
    assert "path" in waitForCompletions(manager.completer)


def test_latestRequestWins(manager):
    for script in ("g.a", "g.ad", "g.addE"):
        manager.completer.request(script, len(script), True, False)
    assert waitForCompletions(manager.completer) == ["addEdge"]


def test_clearDiscardsPendingRequest(manager):
    manager.completer.request("g.addN", len("g.addN"), True, False)
    manager.completer.clearCompletions()
    # The results of the cancelled request must not show up
    assert waitForCompletions(manager.completer, timeout=3000) == []


def test_docstring(manager):
    script = "g.addNewN"
    manager.completer.request(script, len(script), True, False)
    assert waitForCompletions(manager.completer) == ["addNewNode"]
    manager.completer.requestDocstring(0)
    assert waitForSignal(manager.completer.docstringChanged)
    assert "Create and add a new node to the graph." in manager.completer.docstring
    # New completions reset the docstring
    script = "g.addE"
    manager.completer.request(script, len(script), True, False)
    waitForCompletions(manager.completer)
    assert manager.completer.docstring == ""


def test_truncatedDocstring(manager):
    manager.process(f"def longDoc():\n    '''{'a' * 5000}'''")
    script = "longDo"
    manager.completer.request(script, len(script), True, False)
    assert waitForCompletions(manager.completer) == ["longDoc"]
    manager.completer.requestDocstring(0)
    assert waitForSignal(manager.completer.docstringChanged)
    assert len(manager.completer.docstring) < 3100
    assert manager.completer.docstring.endswith("[...]")

def test_signatures(manager):
    manager.process("def myFunction(first, second: int = 2):\n    '''Do <something>.'''")
    script = "myFunction(1, "
    manager.completer.request(script, len(script), False, True)
    assert waitForSignal(manager.completer.signaturesChanged)
    signatures = manager.completer.signatures
    assert len(signatures) == 1
    # The parameter being typed is in bold, and the text is escaped for rich text
    assert signatures[0]["label"] == "myFunction(first, <b>second: int=2</b>)"
    assert signatures[0]["docstring"] == "Do <something>."


def test_signaturesOutsideOfCall(manager):
    script = "myFunction(1, 2)"
    manager.completer.request(script, len(script), False, True)
    assert waitForSignal(manager.completer.signaturesChanged)
    assert manager.completer.signatures == []


def test_completionsAndSignatures(manager):
    # Completing an argument of a call: both are provided by the same request
    script = "myFunction(g.addN"
    manager.completer.request(script, len(script), True, True)
    assert waitForCompletions(manager.completer) == ["addNewNode", "addNode"]
    assert manager.completer.signatures[0]["label"].startswith("myFunction(<b>first</b>")

