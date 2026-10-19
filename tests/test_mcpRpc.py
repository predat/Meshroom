import json
import logging
import threading

import pytest

from meshroom.mcp.rpc import Dispatcher, Tool


def call(dispatcher, message):
    line = message if isinstance(message, bytes) else json.dumps(message).encode()
    reply = dispatcher.handle(line)
    return None if reply is None else json.loads(reply)


def request(method, requestId=1, **params):
    return {"jsonrpc": "2.0", "id": requestId, "method": method, "params": params}


def textTool(handler, name="echo"):
    return Tool(name, "test tool", {"type": "object", "properties": {}}, handler)


class TestInitialize:
    @pytest.mark.parametrize("requested, expected", [
        ("2025-11-25", "2025-11-25"),
        ("2025-06-18", "2025-06-18"),
        ("2024-11-05", "2025-11-25"),
        (None, "2025-11-25"),
    ])
    def test_versionNegotiation(self, requested, expected):
        reply = call(Dispatcher("1.0"), request("initialize", protocolVersion=requested))
        assert reply["result"]["protocolVersion"] == expected
        assert reply["result"]["capabilities"] == {"tools": {}}
        assert reply["result"]["serverInfo"] == {"name": "meshroom", "version": "1.0"}

    @pytest.mark.parametrize("requestId", [0, "server-discover-probe-1", 42])
    def test_idIsEchoedUnchanged(self, requestId):
        reply = call(Dispatcher("1.0"), request("initialize", requestId=requestId, protocolVersion="2025-11-25"))
        assert reply["id"] == requestId
        assert type(reply["id"]) is type(requestId)


class TestDispatch:
    def test_serverDiscoverIsMethodNotFound(self):
        reply = call(Dispatcher("1.0"), request("server/discover", requestId="server-discover-probe-1"))
        assert reply["error"]["code"] == -32601
        assert reply["id"] == "server-discover-probe-1"

    def test_unknownMethod(self):
        assert call(Dispatcher("1.0"), request("resources/list", requestId=0))["error"]["code"] == -32601

    def test_notificationsAndClientResponsesGetNoReply(self):
        dispatcher = Dispatcher("1.0")
        assert call(dispatcher, {"jsonrpc": "2.0", "method": "notifications/initialized"}) is None
        assert call(dispatcher, {"jsonrpc": "2.0", "id": 3, "result": {}}) is None

    def test_invalidMessages(self):
        dispatcher = Dispatcher("1.0")
        parseError = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        assert call(dispatcher, b"{not json") == parseError
        assert call(dispatcher, [request("ping")])["error"]["code"] == -32600
        assert call(dispatcher, {"id": 1, "method": "ping"})["error"]["code"] == -32600
        assert call(dispatcher, {"jsonrpc": "2.0", "id": 1})["error"]["code"] == -32600
        assert call(dispatcher, {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": [1]})["error"]["code"] == -32602

    def test_pingAndEmptyToolList(self):
        dispatcher = Dispatcher("1.0")
        assert call(dispatcher, request("ping"))["result"] == {}
        assert call(dispatcher, request("tools/list"))["result"] == {"tools": []}


class TestToolsCall:
    def test_unknownTool(self):
        reply = call(Dispatcher("1.0"), request("tools/call", name="nope", arguments={}))
        assert reply["error"]["code"] == -32602

    def test_resultShape(self):
        tool = textTool(lambda args: {"content": [{"type": "text", "text": args["x"]}], "isError": False})
        dispatcher = Dispatcher("1.0", [tool])
        assert call(dispatcher, request("tools/list"))["result"]["tools"] == [tool.declaration()]
        reply = call(dispatcher, request("tools/call", name="echo", arguments={"x": "hello"}))
        assert reply["result"] == {"content": [{"type": "text", "text": "hello"}], "isError": False}

    def test_exceptionBecomesIsError(self):
        def handler(args):
            raise ValueError("bad value")
        reply = call(Dispatcher("1.0", [textTool(handler)]), request("tools/call", name="echo"))
        assert reply["result"]["isError"] is True
        assert reply["result"]["content"][0]["text"] == "ValueError: bad value"

    def test_warningsLoggedDuringTheCallAreReturned(self):
        def handler(args):
            logging.info("not returned")
            logging.warning("returned warning")
            logging.getLogger("meshroom.sub").error("returned error")
            other = threading.Thread(target=lambda: logging.error("other thread, not returned"))
            other.start()
            other.join()
            return {"content": [], "isError": False}
        dispatcher = Dispatcher("1.0", [textTool(handler)])
        result = call(dispatcher, request("tools/call", name="echo"))["result"]
        assert result["isError"] is False
        assert result["content"] == [{"type": "text", "text": "Meshroom log during this call:\n"
                                                              "WARNING: returned warning\nERROR: returned error"}]
        # The capture is removed after the call
        assert not any(type(h).__name__ == "LogCapture" for h in logging.getLogger().handlers)
