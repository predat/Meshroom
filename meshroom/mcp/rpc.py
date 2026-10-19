"""
Minimal MCP server side: JSON-RPC 2.0 messages, one per line, dispatched to MCP methods.

Standard library only, no Qt: the transport hands over one line and writes back the returned one.
"""

import json
import logging
import threading
from typing import Callable, Dict, List, Optional

# Supported MCP revisions, preferred first.
PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18")

PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603


class Tool:
    """An MCP tool: its declaration for 'tools/list' and the function called by 'tools/call'."""

    def __init__(
        self,
        name: str,
        description: str,
        inputSchema: dict,
        handler: Callable[[dict], dict],
    ):
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        # Returns an MCP tool result: {"content": [...], "isError": bool}
        self.handler = handler

    def declaration(self) -> dict:
        return {
            "name": self.name,
            "description": self.description,
            "inputSchema": self.inputSchema,
        }


class LogCapture(logging.Handler):
    """Context manager collecting the records >= WARNING emitted by the current thread."""

    def __init__(self):
        super().__init__(logging.WARNING)
        self.threadId = threading.get_ident()
        self.lines: List[str] = []

    def emit(self, record):
        if record.thread == self.threadId:
            self.lines.append(f"{record.levelname}: {record.getMessage()}")

    def __enter__(self):
        logging.getLogger().addHandler(self)
        return self

    def __exit__(self, *exc):
        logging.getLogger().removeHandler(self)
        return False


def response(requestId, result: dict) -> bytes:
    return json.dumps({"jsonrpc": "2.0", "id": requestId, "result": result}).encode()


def errorResponse(requestId, code: int, message: str) -> bytes:
    return json.dumps(
        {"jsonrpc": "2.0", "id": requestId, "error": {"code": code, "message": message}}
    ).encode()


class Dispatcher:
    """Answer one JSON-RPC message (bytes) with one response (bytes), or None for notifications."""

    def __init__(self, serverVersion: str, tools: Optional[List[Tool]] = None):
        self.serverInfo = {"name": "meshroom", "version": serverVersion}
        self.tools: Dict[str, Tool] = {t.name: t for t in tools or []}

    def handle(self, line: bytes) -> Optional[bytes]:
        try:
            message = json.loads(line)
        except ValueError:
            return errorResponse(None, PARSE_ERROR, "Parse error")
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return errorResponse(
                None, INVALID_REQUEST, "Invalid Request: expected a JSON-RPC 2.0 object"
            )

        hasId = "id" in message
        requestId = message.get("id")
        method = message.get("method")
        if not isinstance(method, str):
            if hasId and ("result" in message or "error" in message):
                return (
                    None  # A response from the client: this server never sends requests
                )
            return errorResponse(
                requestId, INVALID_REQUEST, "Invalid Request: missing 'method'"
            )
        if not hasId:
            return None  # Notification (e.g. notifications/initialized): no response

        params = message.get("params") or {}
        if not isinstance(params, dict) or not isinstance(
            params.get("arguments") or {}, dict
        ):
            return errorResponse(
                requestId, INVALID_PARAMS, "Invalid params: expected an object"
            )
        try:
            return self._dispatch(requestId, method, params)
        except Exception:
            logging.exception(f"[MCP] Error while handling '{method}'")
            return errorResponse(
                requestId, INTERNAL_ERROR, "Internal error, see the Meshroom log"
            )

    def _dispatch(self, requestId, method: str, params: dict) -> bytes:
        if method == "initialize":
            return response(requestId, self._initialize(params))
        if method == "ping":
            return response(requestId, {})
        if method == "tools/list":
            return response(
                requestId, {"tools": [t.declaration() for t in self.tools.values()]}
            )
        if method == "tools/call":
            tool = self.tools.get(params.get("name"))
            if tool is None:
                return errorResponse(
                    requestId, INVALID_PARAMS, f"Unknown tool: {params.get('name')!r}"
                )
            return response(
                requestId, self._callTool(tool, params.get("arguments") or {})
            )
        return errorResponse(requestId, METHOD_NOT_FOUND, f"Method not found: {method}")

    def _initialize(self, params: dict) -> dict:
        requested = params.get("protocolVersion")
        version = requested if requested in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
        clientInfo = params.get("clientInfo") or {}
        logging.info(
            f"[MCP] initialize: client {clientInfo.get('name')!r} {clientInfo.get('version')!r}, "
            f"protocol {requested!r} -> {version}"
        )
        return {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": self.serverInfo,
        }

    @staticmethod
    def _callTool(tool: Tool, arguments: dict) -> dict:
        # Meshroom swallows many errors and only logs them (e.g. UndoStack.tryAndPush):
        # return what was logged during the call along with the result.
        with LogCapture() as capture:
            try:
                result = tool.handler(arguments)
            except Exception as e:
                logging.debug(f"[MCP] Tool '{tool.name}' failed", exc_info=True)
                result = {
                    "content": [{"type": "text", "text": f"{type(e).__name__}: {e}"}],
                    "isError": True,
                }
        if capture.lines:
            result = dict(result)
            result["content"] = list(result.get("content", [])) + [
                {
                    "type": "text",
                    "text": "Meshroom log during this call:\n"
                    + "\n".join(capture.lines),
                }
            ]
        return result
