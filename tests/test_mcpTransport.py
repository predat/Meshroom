import os
import shutil
import socket
import stat
import subprocess
import tempfile
import time

import pytest
from PySide6.QtCore import QCoreApplication

from meshroom.mcp.transport import MAX_MESSAGE_SIZE, McpServer, socketPath, socketPid


def waitFor(condition, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        QCoreApplication.processEvents()
        if condition():
            return True
        time.sleep(0.005)
    return False


class Client:
    """ Non-blocking stdlib client, so that the test keeps running the Qt event loop. """
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.sock.setblocking(False)
        self.received = b""
        self.closed = False

    def send(self, data):
        """ Send while running the event loop: a large message does not fit in the socket buffer. """
        view = memoryview(data)
        while view:
            try:
                view = view[self.sock.send(view):]
            except BlockingIOError:
                QCoreApplication.processEvents()
            except (BrokenPipeError, ConnectionResetError):
                return  # Disconnected by the server

    def _poll(self):
        try:
            data = self.sock.recv(1 << 16)
        except BlockingIOError:
            return
        if data:
            self.received += data
        else:
            self.closed = True

    def readLine(self):
        assert waitFor(lambda: self._poll() or b"\n" in self.received or self.closed), "no reply"
        line, _, self.received = self.received.partition(b"\n")
        return line

    def waitClosed(self):
        return waitFor(lambda: self._poll() or self.closed)


def makeUnixSocket(path, listening):
    """ A socket file: still listened on (live instance) or closed without unlink (crashed instance). """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    if listening:
        sock.listen(1)
        return sock
    sock.close()


@pytest.fixture
def runtimeDir(monkeypatch):
    # Short path: Unix socket paths are limited to 108 bytes
    path = tempfile.mkdtemp(prefix="mrmcp-", dir=os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
    monkeypatch.setenv("XDG_RUNTIME_DIR", path)
    yield path
    shutil.rmtree(path)


@pytest.fixture
def server(runtimeDir):
    QCoreApplication.instance() or QCoreApplication([])
    calls = []

    def handleMessage(line):
        calls.append(line)
        return b"reply:" + line
    mcpServer = McpServer(handleMessage)
    mcpServer.calls = calls
    assert mcpServer.start()
    yield mcpServer
    mcpServer.stop()


def test_socketIsPrivateAndRemovedOnStop(server):
    path = socketPath(os.getpid())
    assert server.socketPath == path
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    server.stop()
    assert not server.running
    assert not os.path.exists(path)


def test_framing(server):
    client = Client(server.socketPath)
    client.send(b'{"a"')
    client.send(b':1}\n\n{"b":2}\n')
    assert client.readLine() == b'reply:{"a":1}'
    assert client.readLine() == b'reply:{"b":2}'
    assert server.calls == [b'{"a":1}', b'{"b":2}']


def test_oversizedMessageDisconnects(server):
    client = Client(server.socketPath)
    client.send(b"x" * (MAX_MESSAGE_SIZE + 1))
    assert b'"code": -32600' in client.readLine()
    assert client.waitClosed()
    assert server.calls == []


def test_oneClientAtATime(server):
    first = Client(server.socketPath)
    first.send(b"1\n")
    assert first.readLine() == b"reply:1"
    second = Client(server.socketPath)
    assert second.waitClosed()
    first.send(b"2\n")
    assert first.readLine() == b"reply:2"
    # Once the first client leaves, a new one is accepted
    first.sock.close()
    assert waitFor(lambda: server._client is None)
    third = Client(server.socketPath)
    third.send(b"3\n")
    assert third.readLine() == b"reply:3"


def deadPid():
    """ The pid of a process that just exited. """
    process = subprocess.Popen(["true"])
    process.wait()
    return process.pid


def test_socketPid(runtimeDir):
    assert socketPid(socketPath(1234)) == 1234
    assert socketPid(os.path.join(runtimeDir, "meshroom-mcp-x.sock")) is None
    assert socketPid(os.path.join(runtimeDir, "other-1234.sock")) is None


def test_orphanSocketsRemovedAtStart(runtimeDir):
    QCoreApplication.instance() or QCoreApplication([])
    orphan = socketPath(deadPid())
    ownStale = socketPath(os.getpid())  # Leftover of a dead instance which had the same pid
    # Not listened on, but its process is alive: kept, which also shows no connection is attempted
    alivePid = socketPath(os.getppid())
    regularFile = socketPath(deadPid())  # Dead pid, but not a socket: kept
    unrelated = os.path.join(runtimeDir, "meshroom-mcp-x.sock")
    for path in (orphan, ownStale, alivePid, unrelated):
        makeUnixSocket(path, listening=False)
    open(regularFile, "w").close()

    mcpServer = McpServer(lambda line: None)
    try:
        assert mcpServer.start()
        assert not os.path.exists(orphan)
        assert os.path.exists(alivePid)
        assert os.path.exists(regularFile)
        assert os.path.exists(unrelated)
        assert stat.S_ISSOCK(os.stat(ownStale).st_mode)
        Client(ownStale)  # Ours now
    finally:
        mcpServer.stop()
