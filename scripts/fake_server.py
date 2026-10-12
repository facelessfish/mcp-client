#!/usr/bin/env python3
"""Fake MCP server (stdlib only, Python 3.6+) — Streamable HTTP on /mcp.

Dev/test companion for Faceless MCP Client. Default mode speaks the 2025 session
protocol: initialize -> Mcp-Session-Id -> notifications/initialized -> tools/*.

With --stateless it speaks 2026-07-28 instead and is STRICT on purpose: no sessions,
no handshake, and it validates everything the spec says a modern server must —
    · MCP-Protocol-Version / Mcp-Method / Mcp-Name headers present and matching
    · params._meta["io.modelcontextprotocol/protocolVersion"] present (bare
      `protocolVersion` is NOT accepted — that was a client bug) and equal to the
      header, else 400/-32602 or 400/-32020 HeaderMismatch
    · params._meta["io.modelcontextprotocol/clientCapabilities"] present
      (400/-32602), and --require-capability NAME => 400/-32021
    · x-mcp-header parameters mirrored into Mcp-Param-* using =?base64?…?= when
      needed, while STAYING in arguments (mirrored, not moved)
    · CacheableResult on tools/list + server/discover: resultType, ttlMs, cacheScope
    · icons: serverInfo.icons and tools[].icons (light/dark, themeless, and a
      deliberately undecodable src) — see the icon notes below
    · initialize => 404 / -32601, GET/DELETE => 405, Mcp-Session-Id ignored
Use it to prove the client really negotiates 2026 instead of quietly downgrading.

Wire shapes deliberately mirror common real-world servers:
  * POST without a known Mcp-Session-Id  -> HTTP 400, JSON-RPC -32000
    "Bad Request: No valid session ID provided"
    (exactly what makes Faceless MCP Client's Auto mode fall back from the 2026 probe)
  * known-but-expired session            -> HTTP 404 "Session not found"
    (exercises the client's auto re-handshake)
  * responses are text/event-stream      (single events for normal calls;
    real notifications/progress for the `progress` tool)

serverInfo (the session initialize result, and _meta / discover in stateless
mode) announces two `icons` entries — light- and dark-theme PNGs as base64
data URIs, like the GitHub MCP server does — so the client's theme-aware icon
selection is testable by toggling the OS appearance. The same per-tool shape
(`tools[].icons`) is announced too: echo carries a light+dark pair, add one
themeless icon, boom an undecodable data URI, the rest none — exercising the
client's tool-icon pick, fallbacks and row alignment.

`tools[].annotations` mirror the GitHub pattern: echo/add declare a display
`title` + readOnlyHint/idempotentHint, boom/sleepy ONLY a title (GitHub never
sets the top-level Tool.title, so title resolution must fall through to
`annotations.title`), deploy declares destructiveHint True — and profile
advertises no annotations at all, so mixed rows are covered.

Tools:
  echo     {text}                 -> "echo: <text>"
  add      {a, b}                 -> sum + structuredContent
  boom     {}                     -> isError result (HTTP 200, tool error)
  sleepy   {seconds=8}            -> plain JSON after N s  (test Cancel mid-call)
  progress {steps=5, delay=0.7}   -> SSE: notifications/progress then result
                                     (uses params._meta.progressToken)
  profile  {rich schema}          -> echoes structured args back
                                     (string/int/number/bool/enum/array/object —
                                      use it to test the M2 dynamic form)

Extra tools in --stateless mode:
  deploy      {region*, service*, replicas}  x-mcp-header: Region / Replicas — the
                                 client must send Mcp-Param-Region +
                                 Mcp-Param-Replicas AND keep them in arguments; the
                                 reply shows what arrived on each channel.
  need_input  {prompt}           answers resultType=input_required (MRTR) so you can
                                 check the client flags it instead of calling it a
                                 normal success.

Flags:
  --port 8777
  --require-auth TOKEN    401 unless Authorization: Bearer TOKEN is present
  --expire-after N        invalidate a session after N successful calls (session mode)
  --stateless             2026-07-28 protocol, strict validation (see above)
  --loose                 with --stateless: log violations and answer anyway
  --versions A,B,C        protocol versions advertised in UnsupportedProtocolVersion
                          (default: 2026-07-28)
  --require-capability N  with --stateless: 400/-32021 unless clientCapabilities has N
                          (repeatable; e.g. origins:elicit)
  --with-bad-schema       add a tool whose x-mcp-header annotation breaks the spec
                          (type number) — the client should warn about it
  --mrtr-tools-list       with --stateless: the FIRST tools/list answers
                          resultType=input_required — MRTR beyond tools/call,
                          which the client must flag anyway

Usage:
  python3 scripts/fake_server.py
  python3 scripts/fake_server.py --expire-after 2
  python3 scripts/fake_server.py --require-auth secret123
  python3 scripts/fake_server.py --stateless            # era: Auto must land on 2026
  python3 scripts/fake_server.py --stateless --require-capability origins:elicit
  python3 scripts/fake_server.py --stateless --versions 2025-11-25,2026-07-28
"""

import argparse
import base64
import json
import struct
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

try:
    from http.server import ThreadingHTTPServer
except ImportError:  # Python 3.6: no ThreadingHTTPServer yet
    from socketserver import ThreadingMixIn

    class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True

SUPPORTED_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"]
STATELESS_VERSION = "2026-07-28"

# ---- announced icons (spec Icon[]) ------------------------------------------
# serverInfo carries a light- and a dark-theme PNG (mirrors what the GitHub
# MCP server announces) so theme-aware icon selection can be checked by
# toggling the OS appearance. Generated with stdlib only: solid square with a
# centred circle, two colour sets.

def _png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def _icon_png(size, bg, fg):
    c = (size - 1) / 2.0
    r2 = (size * 0.31) ** 2
    rows = b""
    for y in range(size):
        row = bytearray(b"\x00")  # scanline filter type 0
        for x in range(size):
            row += bytes(fg if (x - c) ** 2 + (y - c) ** 2 <= r2 else bg)
        rows += bytes(row)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)  # RGB, 8-bit
    return (b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", ihdr)
            + _png_chunk(b"IDAT", zlib.compress(rows, 9)) + _png_chunk(b"IEND", b""))


def _data_uri(mime, data):
    return "data:%s;base64,%s" % (mime, base64.b64encode(data).decode("ascii"))


ICONS = [
    {"src": _data_uri("image/png", _icon_png(48, (201, 216, 236), (43, 59, 95))),
     "mimeType": "image/png", "sizes": ["48x48"], "theme": "light"},
    {"src": _data_uri("image/png", _icon_png(48, (24, 27, 38), (169, 192, 239))),
     "mimeType": "image/png", "sizes": ["48x48"], "theme": "dark"},
]

SERVER_INFO = {"name": "FakeMCP", "version": "0.1", "icons": ICONS}

TOOLS = [
    {
        "name": "echo",
        "description": "Returns the text back, prefixed with 'echo:'.",
        "annotations": {"title": "Echo the text",
                        "readOnlyHint": True, "idempotentHint": True},
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string", "description": "Text to echo"}},
            "required": ["text"],
        },
    },
    {
        "name": "add",
        "description": "Adds two numbers and returns the sum as text + structuredContent.",
        "annotations": {"title": "Add two numbers",
                        "readOnlyHint": True, "idempotentHint": True},
        "inputSchema": {
            "type": "object",
            "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
            "required": ["a", "b"],
        },
    },
    {
        "name": "boom",
        "description": "Always fails: isError=true result over HTTP 200 (tool-error rendering test).",
        "annotations": {"title": "Explode loudly"},
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "sleepy",
        "description": "Waits N seconds, then answers as plain JSON. Cancel mid-call to test cancellation.",
        "annotations": {"title": "Sleep, then answer", "readOnlyHint": True},
        "inputSchema": {
            "type": "object",
            "properties": {"seconds": {"type": "number", "default": 8}},
        },
    },
    {
        "name": "progress",
        "description": "Streams notifications/progress over SSE, then answers (progress UI test).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "steps": {"type": "integer", "default": 5},
                "delay": {"type": "number", "default": 0.7},
            },
        },
    },
    {
        "name": "profile",
        "description": "Rich-schema tool: accepts mixed types and echoes them back as structuredContent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Full name"},
                "age": {"type": "integer", "minimum": 0},
                "score": {"type": "number"},
                "active": {"type": "boolean", "default": True},
                "role": {"type": "string", "enum": ["admin", "editor", "viewer"]},
                "tags": {"type": "array", "items": {"type": "string"}},
                "address": {
                    "type": "object",
                    "properties": {
                        "street": {"type": "string"},
                        "city": {"type": "string"},
                        "zip": {"type": "string"},
                    },
                },
            },
            "required": ["name"],
        },
    },
]


# --stateless extras: tools that exist to exercise the 2026 wire rules.
STATELESS_TOOLS = [
    {
        "name": "deploy",
        "description": "x-mcp-header test: region/replicas must ALSO arrive as "
                       "Mcp-Param-Region / Mcp-Param-Replicas headers (and stay in arguments).",
        "annotations": {"title": "Deploy a service",
                        "readOnlyHint": False, "destructiveHint": True,
                        "idempotentHint": False},
        "inputSchema": {
            "type": "object",
            "properties": {
                "region": {"type": "string", "x-mcp-header": "Region",
                           "description": "mirrored to Mcp-Param-Region"},
                "replicas": {"type": "integer", "x-mcp-header": "Replicas",
                             "description": "mirrored to Mcp-Param-Replicas"},
                "service": {"type": "string", "description": "body-only parameter"},
            },
            "required": ["region", "service"],
        },
    },
    {
        "name": "need_input",
        "description": "Answers resultType=input_required (MRTR) — the client must flag "
                       "this as the server asking for input, not a normal success.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]

# ---- per-tool announced icons (spec Icon[] on tools[]) ----------------------
# Mirrors what the GitHub MCP server actually sends: base64 PNG data URIs,
# light + dark variants per tool. Coverage:
#   echo   -> light+dark pair (toggle the OS appearance: the icon swaps)
#   add    -> single themeless icon (themeless fallback pick)
#   boom   -> undecodable data URI (must render as an empty slot, never crash)
#   rest   -> no icons at all (mixed list stays aligned on the reserved slots)
TOOL_ICONS = {
    "echo": [
        {"src": _data_uri("image/png", _icon_png(24, (140, 170, 238), (35, 48, 87))),
         "mimeType": "image/png", "theme": "light"},
        {"src": _data_uri("image/png", _icon_png(24, (49, 57, 85), (137, 180, 250))),
         "mimeType": "image/png", "theme": "dark"},
    ],
    "add": [
        {"src": _data_uri("image/png", _icon_png(24, (245, 194, 231), (90, 44, 79))),
         "mimeType": "image/png"},
    ],
    "boom": [
        {"src": "data:image/png;base64,@@not-really-base64@@", "mimeType": "image/png"},
    ],
}
for _tool in TOOLS + STATELESS_TOOLS:
    if _tool["name"] in TOOL_ICONS:
        _tool["icons"] = TOOL_ICONS[_tool["name"]]

# Deliberately invalid: x-mcp-header on a `number` is forbidden, so a conformant
# client must drop the tool (ours logs a warning and keeps it, being a debugger).
BAD_ANNOTATION_TOOL = {
    "name": "bad_annotation",
    "description": "Invalid tool definition on purpose (x-mcp-header on type number).",
    "inputSchema": {
        "type": "object",
        "properties": {"ratio": {"type": "number", "x-mcp-header": "Ratio"}},
    },
}

# name -> inputSchema, so the stateless path can validate x-mcp-header mirroring.
TOOL_SCHEMAS = {t["name"]: (t.get("inputSchema") or {})
                for t in TOOLS + STATELESS_TOOLS + [BAD_ANNOTATION_TOOL]}

# Methods that carry the required Mcp-Name header, and the body field it mirrors.
NAME_HEADER_METHODS = {"tools/call": "name", "prompts/get": "name", "resources/read": "uri"}

META_VERSION = "io.modelcontextprotocol/protocolVersion"
META_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"
BASE64_PREFIX, BASE64_SUFFIX = "=?base64?", "?="


def decode_header_value(raw):
    """Reverse the spec's =?base64?{Base64}?= encoding; None when undecodable."""
    if raw is None:
        return None
    if raw.startswith(BASE64_PREFIX) and raw.endswith(BASE64_SUFFIX):
        try:
            return base64.b64decode(raw[len(BASE64_PREFIX):-len(BASE64_SUFFIX)]).decode("utf-8")
        except Exception:
            return None
    return raw


def header_plain_text(value):
    """Header string form of a mirrorable value (string / integer / boolean), else None."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, str):
        return value
    return None


def rpc_result(result, mid):
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def rpc_error(code, message, mid=None):
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}


class Handler(BaseHTTPRequestHandler):
    server_version = "FakeMCP/0.1"
    # HTTP/1.0: every response closes the connection — keeps SSE streaming
    # trivial (no chunked encoding needed) and matches URLSession fine.
    protocol_version = "HTTP/1.0"

    # ---- plumbing -------------------------------------------------------

    def log_message(self, fmt, *args):  # quieter default logging
        print("  " + (fmt % args))

    def _path(self):
        return urlparse(self.path).path

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send_json(self, status, payload=None, extra=None):
        try:
            body = b"" if payload is None else json.dumps(payload).encode("utf-8")
            self.send_response(status)
            if payload is not None:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if body:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client went away — nothing to report

    def _sse(self, obj):
        self.wfile.write(b"data: " + json.dumps(obj).encode("utf-8") + b"\n\n")
        self.wfile.flush()

    def _authed(self):
        token = self.server.require_auth
        if not token:
            return True
        return self.headers.get("Authorization", "") == "Bearer " + token

    def _session(self):
        sid = self.headers.get("Mcp-Session-Id")
        with self.server.lock:
            return sid, self.server.sessions.get(sid) if sid else None

    # ---- verbs ----------------------------------------------------------

    def do_GET(self):
        if self._path() == "/mcp":
            # Spec: servers that don't offer a server->client SSE stream answer 405.
            self._send_json(405)
        else:
            self._send_json(404)

    def do_DELETE(self):
        if self.server.stateless:
            # 2026-07-28 has no sessions: DELETE is not part of the protocol.
            return self._send_json(405)
        if self._path() != "/mcp":
            return self._send_json(404)
        if not self._authed():
            return self._send_json(401, rpc_error(-32001, "Unauthorized"))
        sid = self.headers.get("Mcp-Session-Id")
        with self.server.lock:
            gone = self.server.sessions.pop(sid, None)
        print(f"DELETE session {sid} -> {'ended' if gone else 'unknown'}")
        self._send_json(200)

    def do_POST(self):
        if self._path() != "/mcp":
            return self._send_json(404, rpc_error(-32601, "Not found"))
        if not self._authed():
            return self._send_json(
                401, rpc_error(-32001, "Unauthorized: missing bearer token"))

        raw = self._body()
        try:
            msg = json.loads(raw.decode("utf-8"))
        except Exception:
            return self._send_json(400, rpc_error(-32700, "Parse error"))

        method = msg.get("method")
        mid = msg.get("id")
        params = msg.get("params") or {}
        print(f"POST {method} id={mid}" + (f" name={params.get('name')}" if params.get("name") else ""))

        if self.server.stateless:
            return self.handle_stateless(msg)

        # ---- initialize (only request allowed without a session) ----
        if method == "initialize":
            req_ver = params.get("protocolVersion") or ""
            if req_ver == STATELESS_VERSION:
                req_ver = ""  # we don't do stateless; treat as unsupported
            ver = req_ver if req_ver in SUPPORTED_VERSIONS else SUPPORTED_VERSIONS[0]
            sid = str(uuid.uuid4())[:8]
            with self.server.lock:
                self.server.sessions[sid] = {"calls": 0, "initialized": False}
            result = {
                "protocolVersion": ver,
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": SERVER_INFO,
            }
            print(f"  new session {sid} (protocol {ver})")
            return self._send_json(200, rpc_result(result, mid),
                                   extra={"Mcp-Session-Id": sid})

        if method == "notifications/initialized":
            sid, sess = self._session()
            if sess is None:
                return self._send_json(
                    400, rpc_error(-32000, "Bad Request: No valid session ID provided"))
            sess["initialized"] = True
            return self._send_json(202)

        if method == "notifications/cancelled":
            print(f"  (notifications/cancelled received for request id="
                  f"{params.get('requestId')})")
            return self._send_json(202)

        # ---- session gate for all other requests ----
        sid, sess = self._session()
        if sess is None:
            if sid:  # header present but unknown -> expired session (spec: 404)
                return self._send_json(404, rpc_error(-32001, "Session not found", mid))
            # no header at all -> same shape the wild uses, triggers Auto fallback
            return self._send_json(
                400, rpc_error(-32000, "Bad Request: No valid session ID provided", mid))

        if method == "tools/list":
            return self._send_json(200, rpc_result({"tools": TOOLS}, mid))

        if method == "tools/call":
            expired = False
            with self.server.lock:
                sess["calls"] += 1
                if self.server.expire_after and sess["calls"] >= self.server.expire_after:
                    self.server.sessions.pop(sid, None)
                    expired = True
                    print(f"  session {sid} expires after this call "
                          f"(client should re-handshake on the next 404)")
            return self.handle_call(mid, params)

        if mid is None:
            return self._send_json(202)  # unknown notification: accept quietly
        return self._send_json(200, rpc_error(-32601, f"Method not found: {method}", mid))

    # ---- 2026-07-28 stateless path --------------------------------------

    def _rpc(self, result, mid, cacheable=False):
        """Result envelope: decorated with resultType/_meta in stateless mode only.

        cacheable=True marks the 2026 CacheableResult methods (tools/list,
        server/discover): ttlMs and cacheScope are REQUIRED there, exactly what
        the GitHub MCP server sends (ttlMs 0 = no freshness granted, scope public).
        """
        if not getattr(self.server, "stateless", False):
            return rpc_result(result, mid)
        enriched = dict(result)
        enriched.setdefault("resultType", "complete")
        if cacheable:
            enriched.setdefault("ttlMs", 0)
            enriched.setdefault("cacheScope", "public")
        meta = dict(enriched.get("_meta") or {})
        meta.setdefault(META_SERVER_INFO, SERVER_INFO)
        enriched["_meta"] = meta
        return rpc_result(enriched, mid)

    def _reject(self, status, code, message, mid=None, data=None):
        """Log and answer the way a strict modern server must.

        Returns True when the request has been answered with an error — callers must
        `if self._reject(...): return` (a bare `return self._reject(...)` would hang
        the client in --loose mode, where nothing is sent and execution continues so
        one run can surface several violations at once).
        """
        if self.server.loose:
            print(f"  (loose: would reject → HTTP {status} JSON-RPC {code}: {message})")
            return False
        print(f"  REJECT → HTTP {status} JSON-RPC {code}: {message}")
        err = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        self._send_json(status, {"jsonrpc": "2.0", "id": mid, "error": err})
        return True

    def _tools(self):
        tools = list(TOOLS) + list(STATELESS_TOOLS)
        if self.server.bad_schema:
            tools.append(BAD_ANNOTATION_TOOL)
        return tools

    def handle_stateless(self, msg):
        """No sessions, no handshake, per-request metadata, header/body validation on
        every POST — exactly the checks a client's Auto mode leans on."""
        method = msg.get("method")
        mid = msg.get("id")
        params = msg.get("params") or {}

        if self.headers.get("Mcp-Session-Id"):
            print("  (ignoring Mcp-Session-Id)")

        # initialize is not a 2026 method. A 404 *with a JSON-RPC body* is what tells a
        # probing client "modern server" as opposed to "legacy HTTP+SSE server".
        if method == "initialize":
            if self._reject(404, -32601,
                            "Method not found: initialize (2026-07-28 has no handshake)", mid):
                return

        # ---- required headers -------------------------------------------
        # `if self._reject(...)` rather than `return self._reject(...)`: --loose must
        # fall through and still answer, collecting every violation in one run.
        proto = self.headers.get("MCP-Protocol-Version")
        if not proto:
            if self._reject(400, -32020, "missing required header MCP-Protocol-Version", mid):
                return
        elif proto not in self.server.versions:
            if self._reject(400, -32022, "unsupported protocol version " + proto, mid,
                            data={"supported": self.server.versions}):
                return
        else:
            declared = self.headers.get("Mcp-Method")
            if not declared:
                if self._reject(400, -32020, "missing required header Mcp-Method", mid):
                    return
            elif declared != method:
                if self._reject(400, -32020,
                                f"Mcp-Method header {declared!r} does not match body method {method!r}",
                                mid):
                    return
            name_field = NAME_HEADER_METHODS.get(method)
            if name_field is not None and params.get(name_field) is not None:
                want = params[name_field]
                got = decode_header_value(self.headers.get("Mcp-Name"))
                if got is None:
                    if self._reject(400, -32020, "missing required header Mcp-Name", mid):
                        return
                elif got != want:
                    if self._reject(400, -32020,
                                    f"Mcp-Name header {got!r} does not match body {want!r}", mid):
                        return

        # Notifications carry no protocol metadata in this revision: 202 and done.
        if mid is None:
            return self._send_json(202)

        # ---- per-request protocol metadata ------------------------------
        meta = params.get("_meta") or {}
        bare = sorted(k for k in ("protocolVersion", "clientInfo", "clientCapabilities") if k in meta)
        if META_VERSION not in meta:
            hint = f" (unnamespaced {', '.join(bare)} is not a protocol field)" if bare else ""
            if self._reject(400, -32602,
                            f"missing required _meta field {META_VERSION}{hint}", mid):
                return
        elif meta[META_VERSION] != proto:
            if self._reject(400, -32020,
                            f"_meta {META_VERSION} {meta[META_VERSION]!r} does not match "
                            f"MCP-Protocol-Version header {proto!r}", mid):
                return
        if META_CAPABILITIES not in meta:
            if self._reject(400, -32602, f"missing required _meta field {META_CAPABILITIES}", mid):
                return
        else:
            missing = [c for c in self.server.require_capabilities
                       if c not in (meta.get(META_CAPABILITIES) or {})]
            if missing:
                if self._reject(400, -32021, "client is missing required capabilities", mid,
                                data={"requiredCapabilities": missing}):
                    return
        info = meta.get(META_CLIENT_INFO) or {}
        if info:
            print(f"  client: {info.get('name')} {info.get('version')}")

        if method == "tools/call" and self.check_mirrored_headers(mid, params):
            return

        if method == "server/discover":
            # Mandatory discovery RPC of 2026-07-28: versions, capabilities and
            # instructions; _meta serverInfo + resultType come from self._rpc().
            return self._send_json(200, self._rpc({
                "supportedVersions": self.server.versions,
                "capabilities": {"tools": {"listChanged": True}},
                "instructions": "Fake stateless server: try echo, add, boom, sleepy, "
                                "progress, profile, deploy (x-mcp-header), "
                                "need_input (MRTR).",
            }, mid, cacheable=True))
        if method == "tools/list":
            # --mrtr-tools-list: the FIRST tools/list answers input_required —
            # MRTR is not a tools/call-only mechanism, and the client must flag
            # the discriminator wherever it appears, not treat this as an empty
            # tool list. The next tools/list answers normally (Refresh recovers).
            answer_mrtr = False
            if self.server.mrtr_tools_list_left > 0:
                with self.server.lock:
                    if self.server.mrtr_tools_list_left > 0:
                        self.server.mrtr_tools_list_left -= 1
                        answer_mrtr = True
            if answer_mrtr:
                print("  (MRTR: this tools/list answered resultType=input_required)")
                return self._send_json(200, {"jsonrpc": "2.0", "id": mid, "result": {
                    "resultType": "input_required",
                    "inputRequests": {"scope": {
                        "method": "elicitation/create",
                        "params": {"mode": "form", "message": "which tool scope?",
                                   "requestedSchema": {"type": "object",
                                                       "properties": {"scope": {"type": "string"}}}}}},
                    "requestState": "c2NvcGU6YWxs",
                    "_meta": {META_SERVER_INFO: SERVER_INFO}}})
            return self._send_json(200, self._rpc({"tools": self._tools()}, mid, cacheable=True))
        if method == "tools/call":
            return self.call_stateless_tool(mid, params)
        return self._send_json(200, rpc_error(-32601, f"Method not found: {method}", mid))

    def check_mirrored_headers(self, mid, params):
        """Each x-mcp-header parameter must arrive BOTH as Mcp-Param-* and in
        arguments, with the same value; absent/null parameters must send no header.
        (Mirrored, not moved — deleting the argument is a -32020.)"""
        props = (TOOL_SCHEMAS.get(params.get("name")) or {}).get("properties") or {}
        args = params.get("arguments") or {}
        for key, prop in props.items():
            annotation = prop.get("x-mcp-header")
            if not annotation:
                continue
            header = "Mcp-Param-" + annotation
            raw = self.headers.get(header)
            if key not in args or args[key] is None:
                if raw is not None and self._reject(
                        400, -32020, f"{header} sent while {key} is absent/null in the body", mid):
                    return True
                continue
            if raw is None:
                if self._reject(400, -32020,
                                f"{header} missing while the body carries {key}={args[key]!r}", mid):
                    return True
                continue
            decoded = decode_header_value(raw)
            if decoded is None:
                if self._reject(400, -32020, f"{header} is not decodable =?base64?...?= data", mid):
                    return True
                continue
            expected = header_plain_text(args[key])
            if expected is not None and decoded != expected:
                if self._reject(400, -32020,
                                f"{header} {decoded!r} does not match body {key}={args[key]!r}", mid):
                    return True
        return False

    def call_stateless_tool(self, mid, params):
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "deploy":
            mirrored = {}
            for _key, prop in (TOOL_SCHEMAS["deploy"].get("properties") or {}).items():
                annotation = prop.get("x-mcp-header")
                if annotation:
                    mirrored["Mcp-Param-" + annotation] = self.headers.get("Mcp-Param-" + annotation)
            text = ("deploy ok · body=" + json.dumps(args, sort_keys=True)
                    + " · headers=" + json.dumps(mirrored, sort_keys=True))
            return self._send_json(200, self._rpc(
                {"content": [{"type": "text", "text": text}],
                 "structuredContent": {"arguments": args, "mirroredHeaders": mirrored}}, mid))
        if name == "need_input":
            # MRTR: the server wants client input, expressed as a result, not a request.
            return self._send_json(200, {"jsonrpc": "2.0", "id": mid, "result": {
                "resultType": "input_required",
                "inputRequests": {"elicitation": {
                    "method": "elicitation/create",
                    "params": {"message": "which region?",
                               "requestedSchema": {"type": "object",
                                                   "properties": {"region": {"type": "string"}}}}}},
                "_meta": {META_SERVER_INFO: SERVER_INFO}}})
        if name == "bad_annotation":
            return self._send_json(200, self._rpc(
                {"content": [{"type": "text", "text": "bad_annotation: ratio=%r" % (args.get("ratio"),)}]},
                mid))
        return self.handle_call(mid, params)   # echo / add / boom / sleepy / progress / profile

    # ---- tools/call -----------------------------------------------------

    def handle_call(self, mid, params):
        name = params.get("name")
        args = params.get("arguments") or {}

        if name == "progress":
            return self.stream_progress(mid, args, params)

        try:
            if name == "echo":
                result = {"content": [{"type": "text",
                                       "text": "echo: " + str(args.get("text", ""))}]}
            elif name == "add":
                a, b = float(args.get("a", 0)), float(args.get("b", 0))
                s = a + b
                if s == int(s):
                    s = int(s)
                result = {
                    "content": [{"type": "text", "text": f"{a} + {b} = {s}"}],
                    "structuredContent": {"a": a, "b": b, "sum": s},
                }
            elif name == "boom":
                result = {
                    "isError": True,
                    "content": [{"type": "text",
                                 "text": "This tool always fails (isError=true over HTTP 200)."}],
                }
            elif name == "sleepy":
                secs = float(args.get("seconds", 8))
                time.sleep(secs)  # client cancel shows up as BrokenPipe on send
                result = {"content": [{"type": "text",
                                       "text": f"slept {secs}s, then answered"}]}
            elif name == "profile":
                result = {
                    "content": [{"type": "text",
                                 "text": "profile ok: " + json.dumps(args, sort_keys=True)}],
                    "structuredContent": {"echo": args},
                }
            else:
                return self._send_json(200, rpc_error(-32602, f"Unknown tool: {name}", mid))
            self._send_json(200, self._rpc(result, mid))
        except (BrokenPipeError, ConnectionResetError):
            print(f"  (client disconnected during {name} — treated as cancelled)")
        except Exception as e:
            self._send_json(200, rpc_error(-32603, f"Internal error: {e}", mid))

    def stream_progress(self, mid, args, params):
        steps = int(args.get("steps", 5))
        delay = float(args.get("delay", 0.7))
        token = (params.get("_meta") or {}).get("progressToken")
        if token is None:
            token = "srv-" + uuid.uuid4().hex[:6]
            print("  (no _meta.progressToken — using our own token)")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            if getattr(self.server, "stateless", False):
                # Spec SHOULD: keep reverse proxies from buffering the stream.
                self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            self.wfile.write(b": fake server keep-alive comment\n\n")
            self.wfile.flush()
            for i in range(1, steps + 1):
                time.sleep(delay)
                self._sse({"jsonrpc": "2.0", "method": "notifications/progress",
                           "params": {"progressToken": token, "progress": i,
                                      "total": steps, "message": f"step {i}/{steps}"}})
            self._sse(self._rpc({"content": [{"type": "text",
                                              "text": f"done after {steps} steps"}]}, mid))
            print("  (progress stream finished)")
        except (BrokenPipeError, ConnectionResetError):
            print("  (client closed stream during progress — cancelled)")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--require-auth", metavar="TOKEN", default=None,
                    help="401 unless Authorization: Bearer TOKEN")
    ap.add_argument("--expire-after", metavar="N", type=int, default=None,
                    help="invalidate each session after N successful calls (session mode)")
    ap.add_argument("--stateless", action="store_true",
                    help="speak 2026-07-28: no sessions, strict header/_meta validation")
    ap.add_argument("--loose", action="store_true",
                    help="with --stateless: log violations instead of rejecting")
    ap.add_argument("--versions", default=None, metavar="A,B,C",
                    help="protocol versions to advertise (default: %s)" % STATELESS_VERSION)
    ap.add_argument("--require-capability", metavar="NAME", action="append", default=None,
                    help="with --stateless: 400/-32021 unless clientCapabilities lists NAME")
    ap.add_argument("--with-bad-schema", action="store_true",
                    help="add a tool with a spec-breaking x-mcp-header annotation")
    ap.add_argument("--mrtr-tools-list", action="store_true",
                    help="with --stateless: the FIRST tools/list answers "
                         "resultType=input_required (MRTR on a non-tools/call method); "
                         "the next one answers normally")
    args = ap.parse_args()

    if args.loose and not args.stateless:
        ap.error("--loose only applies with --stateless")
    if args.mrtr_tools_list and not args.stateless:
        ap.error("--mrtr-tools-list only applies with --stateless")
    if args.expire_after and args.stateless:
        print("note: --expire-after ignored in --stateless mode")
        args.expire_after = None

    versions = ([v.strip() for v in args.versions.split(",") if v.strip()]
                if args.versions else [STATELESS_VERSION])

    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    srv.sessions = {}
    srv.lock = threading.Lock()
    srv.require_auth = args.require_auth
    srv.expire_after = args.expire_after
    srv.stateless = args.stateless
    srv.loose = args.loose
    srv.bad_schema = args.with_bad_schema
    srv.mrtr_tools_list_left = 1 if args.mrtr_tools_list else 0
    srv.versions = versions
    srv.require_capabilities = args.require_capability or []
    srv.daemon_threads = True

    era = "2026-07-28 stateless, strict" if args.stateless else "2025 session era"
    print(f"Fake MCP server ({era}, tools only) on port {args.port}")
    print(f"  add in Faceless MCP Client:  http://127.0.0.1:{args.port}/mcp   (era: Auto)")
    if args.stateless:
        print("  speaks: %s · rejects: missing/mismatched Mcp-* headers, unnamespaced "
              "_meta, missing clientCapabilities, Mcp-Param/* header-vs-body mismatch"
              % ", ".join(versions))
        print("  try: deploy (x-mcp-header), need_input (MRTR), progress (SSE), sleepy (cancel)")
        if args.mrtr_tools_list:
            print("  first tools/list -> resultType=input_required (the client must flag it "
                  "even though this is not tools/call); next tools/list answers normally")
        if srv.require_capabilities:
            print("  requires clientCapabilities: " + ", ".join(srv.require_capabilities))
        if args.loose:
            print("  LOOSE MODE: violations are logged, requests are answered anyway")
    listed = TOOLS + (STATELESS_TOOLS if args.stateless else [])
    print("  tools: " + ", ".join(t["name"] for t in listed))
    if args.with_bad_schema:
        print("  + bad_annotation (invalid x-mcp-header — the client should warn about it)")
    if args.require_auth:
        print(f"  auth required — add header:  Authorization: Bearer {args.require_auth}")
    if args.expire_after:
        print(f"  sessions expire after {args.expire_after} call(s) — "
              "watch the Log tab for auto re-handshake")
    print("  Ctrl-C to stop")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
