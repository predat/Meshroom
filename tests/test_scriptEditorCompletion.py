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
    manager.completer.requestCompletions(script, len(script))
    assert waitForCompletions(manager.completer) == ["addNewNode", "addNode"]


def test_completeMultiline(manager):
    script = "for i in range(3):\n    i.bit_l"
    manager.completer.requestCompletions(script, len(script))
    names = waitForCompletions(manager.completer)
    assert names == ["bit_length"]
    assert manager.completer.completions[0]["prefixLength"] == len("bit_l")


def test_completeCaseInsensitive(manager):
    # The whole typed prefix is replaced, to fix its case
    script = "g.addnewn"
    manager.completer.requestCompletions(script, len(script))
    assert waitForCompletions(manager.completer) == ["addNewNode"]
    assert manager.completer.completions[0]["prefixLength"] == len("addnewn")


def test_completeAtCursorPosition(manager):
    # Only the text before the cursor is completed
    script = "import os\nos.pa\nprint('end')"
    manager.completer.requestCompletions(script, script.index("\nprint"))
    assert "path" in waitForCompletions(manager.completer)


def test_latestRequestWins(manager):
    for script in ("g.a", "g.ad", "g.addE"):
        manager.completer.requestCompletions(script, len(script))
    assert waitForCompletions(manager.completer) == ["addEdge"]


def test_clearDiscardsPendingRequest(manager):
    manager.completer.requestCompletions("g.addN", len("g.addN"))
    manager.completer.clearCompletions()
    # The results of the cancelled request must not show up
    assert waitForCompletions(manager.completer, timeout=3000) == []

