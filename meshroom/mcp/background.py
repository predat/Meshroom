"""
Work done off the Qt main thread for the MCP tools, with its result handed back on the main thread.

The background work must not touch the Graph, the UIGraph or the TaskManager: it only gets plain data (e.g. paths).
"""
from typing import Callable

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Signal, Slot


class _Task(QRunnable):
    def __init__(self, work: Callable, done: Callable, relay: "BackgroundTasks"):
        super().__init__()
        self._work, self._done, self._relay = work, done, relay

    def run(self):
        try:
            result = self._work()
        except Exception as e:  # Handed to 'done', which decides how to report it
            result = e
        self._relay.finished.emit(self, result)


class BackgroundTasks(QObject):
    """ Must live in the main thread: callbacks run in the thread of this object. """

    finished = Signal(object, object)  # task, result (or the exception raised)

    def __init__(self, parent: QObject = None):
        super().__init__(parent)
        self._tasks = set()  # Keep the Python wrappers alive until the tasks end
        self.finished.connect(self._onFinished)  # Queued: emitted from the pool's threads

    def run(self, work: Callable, done: Callable):
        """ Run work() in a QThreadPool thread, then done(result) in the main thread. """
        task = _Task(work, done, self)
        task.setAutoDelete(False)
        self._tasks.add(task)
        QThreadPool.globalInstance().start(task)

    @Slot(object, object)
    def _onFinished(self, task, result):
        self._tasks.discard(task)
        task._done(result)


class NextEmission(QObject):
    """
    Calls 'callback' once, in the thread of this object (the main thread), the next time 'signal' is emitted,
    even from another thread. cancel() gives up waiting.
    """
    def __init__(self, signal, callback: Callable, parent: QObject):
        super().__init__(parent)
        self._signal, self._callback, self._done = signal, callback, False
        signal.connect(self._onEmitted)  # Queued when emitted from another thread

    @Slot()
    def _onEmitted(self):
        if not self._done:
            self.cancel()
            self._callback()

    def cancel(self):
        if self._done:
            return
        self._done = True
        self._signal.disconnect(self._onEmitted)
        self.deleteLater()
