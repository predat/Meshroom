"""
Unix domain socket transport of the MCP server, served by a QLocalServer on the Qt main thread.

One client at a time, newline-delimited messages, bounded read buffer.
"""

import glob
import logging
import os
import re
import stat
from typing import Callable, Optional

from PySide6.QtCore import QObject, Signal
from PySide6.QtNetwork import QLocalServer, QLocalSocket

from meshroom.mcp.rpc import INVALID_REQUEST, errorResponse

MAX_MESSAGE_SIZE = 1 << 20  # bytes, per message and for the pending read buffer


def socketPattern() -> str:
    """Glob pattern of the sockets of all the Meshroom instances of this user."""
    runtimeDir = os.environ.get("XDG_RUNTIME_DIR")
    if runtimeDir:
        return os.path.join(runtimeDir, "meshroom-mcp-*.sock")
    return f"/tmp/meshroom-mcp-{os.getuid()}-*.sock"


def socketPath(pid: int) -> str:
    return socketPattern().replace("*", str(pid))


def socketPid(path: str) -> Optional[int]:
    """Pid of the instance a socket belongs to, from its name; None if the name does not match."""
    pattern = re.escape(os.path.basename(socketPattern())).replace(r"\*", r"(\d+)")
    match = re.fullmatch(pattern, os.path.basename(path))
    return int(match.group(1)) if match else None


def isProcessAlive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # Exists, owned by another user
    return True


def removeOrphanSockets():
    """
    Unlink the sockets of dead instances (crashed or killed): the pid in their name does not exist anymore.
    Must be called before listening: a socket named after the current pid is a leftover from a dead instance.
    """
    for path in glob.glob(socketPattern()):
        pid = socketPid(path)
        if pid is None:
            continue
        # ponytail: a pid reused by an unrelated process keeps its orphan until that process exits;
        # compare the process start time with the socket mtime if this ever matters.
        if pid != os.getpid() and isProcessAlive(pid):
            continue
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            continue
        if stat.S_ISSOCK(st.st_mode) and st.st_uid == os.getuid():
            logging.info(f"[MCP] Removing orphan socket {path}")
            os.unlink(path)


class McpServer(QObject):
    """Serve 'handleMessage' (one message in, one optional response out) on this instance's socket."""

    runningChanged = Signal()

    def __init__(
        self, handleMessage: Callable[[bytes], Optional[bytes]], parent: QObject = None
    ):
        super().__init__(parent)
        self._handleMessage = handleMessage
        self._server = QLocalServer(self)
        # 0700 at creation, then 0600 once listening
        self._server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
        self._server.newConnection.connect(self._onNewConnection)
        self._client: Optional[QLocalSocket] = None
        self._buffer = bytearray()

    @property
    def running(self) -> bool:
        return self._server.isListening()

    @property
    def socketPath(self) -> str:
        return self._server.fullServerName() if self.running else ""

    def start(self) -> bool:
        if self.running:
            return True
        removeOrphanSockets()
        path = socketPath(os.getpid())
        if not self._server.listen(path):
            logging.error(
                f"[MCP] Cannot listen on {path}: {self._server.errorString()}"
            )
            return False
        os.chmod(path, 0o600)
        logging.info(f"[MCP] Server listening on {path}")
        self.runningChanged.emit()
        return True

    def stop(self):
        if not self.running:
            return
        client = self._client
        if client is not None:
            client.abort()  # May already drop it through 'disconnected'
            self._dropClient(client)
        self._server.close()  # Also removes the socket file
        logging.info("[MCP] Server stopped")
        self.runningChanged.emit()

    def _onNewConnection(self):
        while self._server.hasPendingConnections():
            connection = self._server.nextPendingConnection()
            if self._client is not None:
                logging.warning(
                    "[MCP] Refused a client: another one is already connected"
                )
                connection.abort()
                connection.deleteLater()
                continue
            self._client = connection
            self._buffer = bytearray()
            connection.readyRead.connect(self._onReadyRead)
            connection.disconnected.connect(lambda c=connection: self._dropClient(c))

    def _dropClient(self, connection: QLocalSocket):
        if connection is not self._client:
            return
        self._client = None
        self._buffer = bytearray()
        connection.deleteLater()

    def _onReadyRead(self):
        connection = self._client
        if connection is None:
            return
        self._buffer += connection.readAll().data()
        while connection is self._client:
            end = self._buffer.find(b"\n")
            if end < 0:
                break
            line = bytes(self._buffer[:end])
            del self._buffer[: end + 1]
            if len(line) > MAX_MESSAGE_SIZE:
                self._rejectOversized(connection)
                return
            if not line.strip():
                continue
            reply = self._handleMessage(line)
            if reply is not None and connection is self._client:
                connection.write(reply + b"\n")
        if len(self._buffer) > MAX_MESSAGE_SIZE:
            self._rejectOversized(connection)

    def _rejectOversized(self, connection: QLocalSocket):
        logging.warning(
            f"[MCP] Message larger than {MAX_MESSAGE_SIZE} bytes: disconnecting the client"
        )
        connection.write(
            errorResponse(None, INVALID_REQUEST, "Message too large") + b"\n"
        )
        connection.flush()
        connection.disconnectFromServer()
        self._dropClient(connection)
