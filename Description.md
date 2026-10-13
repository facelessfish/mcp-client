# Faceless MCP Client — Technical Description

This is the internal/technical document: what the app is, how it is built, why it is
built the way it is, and how to test it. The user manual is [README.md](README.md).

## What it is

A native macOS (SwiftUI + AppKit) MCP client whose only job is debugging and testing MCP
servers over the **Streamable HTTP** transport. No LLM, no stdio, no conversation UI. It
keeps a list of servers, connects to them, lists their tools, calls them, and shows
everything that crosses the wire — statuses, headers, bodies, SSE events — verbatim.

Two rules drive every technical decision in the app:

1. **Show what the server sent.** No inference, no truncation, no placeholder artwork.
   A debug console that hides or "helpfully fixes" the wire is worse than no console.
2. **Stay responsive with adversarial payloads.** A server is an arbitrary program: a
   `tools/list` may be several megabytes, a reply may carry megabytes of base64 images.
   Nothing is derived in a view body, no pane grows to the height of its content, and a
   window resize must cost the same for a 2 KB reply as for a 2 MB one.

## Requirements and build

- macOS 14+, Swift 5.9+ toolchain. Command Line Tools are enough — there is no Xcode
  project on purpose; the build is plain SPM plus one shell script.
- `swift run mcp_client` — the dev loop. The `AppDelegate` flips the activation policy
  so the unbundled binary behaves like a real app (dock icon, foreground focus).
- `bash build.sh [debug|release]` — builds with SPM and bundles
  `build/Faceless MCP Client.app`: strips the binary, writes the Info.plist (ATS relaxed
  so cleartext `http://` dev servers work), renders the app icon from
  `icons/AppIcon-1024.svg` (sips → .iconset → icns), ad-hoc codesigns, opens the bundle.
  Release is the default; pass `debug` for a build you can attach a debugger to.

The module, the executable and `swift run` are all `mcp_client` — the app itself is
*Faceless MCP Client*.

## Architecture

```
App.swift ─► Views (SwiftUI) ─► State (@Observable VMs) ─► Protocol (transport) ─► Models
                    ▲                                              │
      Presentation (per-reply derived views) ◄────────────────────┘
```

One SPM executable target, zero external dependencies. Data flows one way: views call
into the view-models, the view-models own a `Connection`, and the transport reports
upward through an `onEvent` closure that posts `TranscriptEntry` rows to the main actor.
The transport knows nothing about the UI.

### Code map

```
Package.swift                        SPM executable — module/product `mcp_client`
build.sh                             build + bundle into Faceless MCP Client.app + app icon
Sources/mcp_client/
  App.swift                          @main + activation for `swift run`
  Models/JSONValue.swift             lossless JSON model + deterministic printer
  Models/Models.swift                ServerConfig, protocol eras, statuses, CallResult, MCPError
  Protocol/JSONRPC.swift             lenient RPC message model, RPCError, SSE line parser
  Protocol/Connection.swift          ★ the transport: headers, eras, SSE, mirroring, transcript
  State/AppModel.swift               servers CRUD + persistence + sash positions
  State/ServerModel.swift            per-server VM: connect/call/cancel, transcript
  Presentation/ResultPresentation.swift  ★ what a call result looks like: printed blocks,
                                     decoded images, line-counted heights — derived once
                                     per reply, never in a view body
  Views/ContentView.swift            NavigationSplitView + HSplitView, detail panes
  Views/SidebarView.swift            server list, context menus, add/remove/edit bar
  Views/ServerEditorSheet.swift      per-server settings (incl. the Authorization field)
  Views/ToolsPane.swift              tool list, filter, chips, icons, tool editor, call row
  Views/SchemaForm.swift             dynamic argument-form widgets
  Views/OutputPane.swift             Result · Raw · Log · Server tabs
  Views/ServerProfile.swift          the Server tab (connection profile cards)
  Views/TextSurface.swift            ★ the one text view of the app: a read-only, selectable
                                     NSTextView in its own NSScrollView (⌘F), plus its
                                     height rules (TextMetrics) and the Prose view
  Views/TextHighlight.swift          JSON colouring and inline-markdown rendering into
                                     NSAttributedString; Catppuccin in AppKit colours
  Views/Icons.swift                  spec Icon[] theme pick + decoded pixels (IconRef),
                                     the row/header tile, image content blocks
  Views/ImageActions.swift           getting a reply's pixels out: format sniffing, save
                                     panel, pasteboard, drag-to-Finder (staged file)
  Views/Utilities.swift              clipboard, palette, draggable sash, flow layout,
                                     grouping card (CardBox), schema example arguments,
                                     byte sizes (ByteSize)
scripts/fake_server.py               stdlib fake MCP server (session era, or --stateless 2026)
icons/AppIcon-1024.svg               app-icon source → PNG → .iconset → AppIcon.icns
```

## What it speaks

Per-server protocol selector, **Auto** by default:

| Era | Behavior |
|---|---|
| `2026-07-28` (stateless) | No handshake; after connecting the client calls `server/discover` (the mandatory discovery RPC) so the Server profile can show identity, capabilities and instructions. `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` headers (name from `params.name`, or `params.uri` for `resources/read`; unsafe values use the spec's `=?base64?…?=` sentinel); the reserved `_meta` keys `io.modelcontextprotocol/protocolVersion` (required), `/clientCapabilities` (required, currently `{}`) and `/clientInfo` in params; `x-mcp-header` parameters **mirrored** to `Mcp-Param-*` headers while staying in `arguments` (a server must be able to compare them); cancel = close the stream. |
| `2025-03-26 … 2025-11-25` (session) | `initialize` → `notifications/initialized`, `Mcp-Session-Id` tracked, 404 → automatic re-handshake + retry once, `DELETE` on disconnect, `notifications/cancelled` on Cancel. |
| Auto | Probes 2026 stateless (`tools/list`). On 400/404/405 it reads the **body**: a modern JSON-RPC error (`-32020` HeaderMismatch, `-32021` MissingRequiredClientCapability, `-32022` UnsupportedProtocolVersion) means the server speaks 2026 → no downgrade, the reason (and any advertised `supported` versions / `requiredCapabilities`) is logged; `-32022` advertising a 2025 version, or any unrecognized/empty body → 2025 handshake. Auth failures (401/403) are never an era hint. Force an era in the server editor to override. |

Methods and mechanics:

- `tools/list` follows pagination (`cursor` / `nextCursor`, capped at 50 pages). Duplicate
  tool names are tolerated (last schema wins — a crash was fixed here).
- Every `tools/call` advertises `params._meta.progressToken` so spec-conformant servers
  actually stream progress; notifications with foreign tokens are ignored.
- Any POST may answer `application/json` **or** a request-scoped `text/event-stream`;
  SSE is parsed inline. Progress shows live next to the Call button and is listed with
  the result.
- `resultType` (2026 discriminator) is flagged for **every** method's result when it is
  not `complete` — MRTR's `input_required` never masquerades as a normal answer.
- Server→client requests (sampling / elicitation / roots) arriving mid-stream are
  answered JSON-RPC `-32601` and logged. Deprecated 2024 HTTP+SSE `endpoint` events are
  flagged, not followed.
- A 200 that is unparseable names the real cause: a body cut short by a dead connection
  is reported as truncation at N bytes, not as "unparseable response".

## Programming decisions

The rationale for everything non-obvious in the code, roughly by cost of getting it wrong.

### 1. Lossless JSON (`JSONValue`)

A hand-rolled recursive enum (`null/bool/int/double/string/array/object`) used for every
payload: schemas, arguments, results, config values. Nothing a server sends can be
silently dropped — including the int/double distinction and unknown keys. The printer is
deterministic (sorted keys, stable output, `2` prints as `2` and `2.0` as `2.0`), so
transcript diffs and ⌘F comparisons are stable. Decoding never throws on unknown shapes.

### 2. Derive once per reply, cache nothing

`ResultPresentation` walks each reply **once**, when it lands: picks the main document
(`structuredContent` → `content[].text` (pretty-printed when the text itself is JSON) →
the whole result as the never-blank fallback), decodes the `image` content blocks, counts
lines, prepares the Raw text. Views only read finished values.

An image is kept as **both** halves of its block: `ReplyImage` holds the decoded bytes and
the pixels drawn from them. Pixels alone would be enough to draw and not enough to hand
back — an `NSImage` has forgotten which format it arrived in, and re-encoding one writes a
different file than the one the server sent. So saving and dragging (`ImageActions`) take
`data`, and the reply's own bytes survive the presentation that displays them.

The app deliberately has **no render cache**. The caches an earlier revision had existed
because derivations ran inside `body` — which runs on every update and every resize tick —
and they paid for themselves with a deep hash of the payload on every lookup. Work that
happens once per call needs no cache: a pretty-print is ~1 ms per 100 KB, an image decode
a handful of ms per MB.

### 3. Text: AppKit owns layout, surfaces never grow

Everything longer than a label goes through `TextSurface` — one read-only, selectable
`NSTextView` in its own `NSScrollView`. Two rules:

- **Text layout happens in AppKit.** SwiftUI never measures a block of text, so it cannot
  measure it once per layout pass or once per animation frame. The represented view
  reports no intrinsic content size at all; the scroll view clamps the document width to
  the viewport on every `tile()`. Content can never be wider than its pane.
- **A surface takes the height it is given** (the pane's, or a fixed one derived from a
  capped hard-line count) **and scrolls inside it.** A page of blocks is a handful of
  constants tall no matter what the server returned.

No display cap exists: text is shown whole, always — a prefix cut would also remove the
tail from the find bar's reach. The only bound in the pipeline is cosmetic: colouring
walks 600 k characters max; beyond that text is still shown, selectable, findable and
copied, just in the base colour. There is no horizontal scroller on purpose — a
multi-megabyte single-line body (base64) would lay out a layer millions of points wide,
which AppKit drops as "bogus layer size" and the content silently disappears. Long tokens
force-break inside the line instead.

The string is handed to AppKit once per content change; the guard is a string identity
compare, so unrelated updates (a log line, a keystroke elsewhere) cost nothing.

`Prose` (tool descriptions, instructions) is the one place SwiftUI still measures, and
only under 1.6 KB, where that is the cheaper of the two paths. Which renderer a passage
landed on used to show in the text itself — different colour, different size. `TextChrome`
now carries face and colour as one decision and `Prose` applies it on **both** paths
(`.callout` + secondary in SwiftUI spelling, the same pair painted into the attributed
string on the AppKit path), so folding a long tool description into a disclosure — or
letting server instructions run past a page — changes its box and not its dress. Both
callers ask `Prose` for the chrome instead of styling it from outside, where it would
stop at the surface's edge.

### 4. Highlighting in one UTF-16 pass

The JSON colourer walks UTF-16 code units once and emits an `NSAttributedString` — no
scanner, no tree. UTF-16 because that is `NSRange`'s coordinate system: the
`AttributedString` version it replaced spent most of its time converting character
offsets to UTF-8 offsets per range (hundreds of ms on a formatted reply). Colours are
*dynamic* `NSColor`s, so a light/dark appearance flip costs zero — the highlighted string
stays valid and the system just redraws.

### 5. SSE framed from raw bytes

URLSession's `bytes.lines` collapses the empty lines that separate SSE events, merging
multi-event streams into one unparseable blob. The client therefore frames lines itself
from `URLSession.AsyncBytes`, feeds a small hand-written parser (comments/keep-alives,
multi-line `data:`, CRLF), and breaks out of the stream the moment the matching response
arrives. A deprecated `endpoint` event is logged. Server→client requests inside the
stream get a `-32601` rejection POST.

Leniency is deliberate where the spec is silent: a response whose `id` doesn't match the
sent id is **accepted with a note** (a server echoing `7` as `"7"` used to surface as the
misleading "stream ended before response"). This is a debugger — it shows the reply and
tells you the id was odd, instead of refusing to show the reply.

### 6. Icons resolved once per tool, off the main actor

Servers announce icons as spec `Icon[]` (`src` = http(s) URL or base64 `data:` URI,
optional `theme`). The theme pick (theme match → themeless → first usable `src`) and the
base64 decode happen **once per tool**, while `tools/list` is still being processed, not
once per row per view update — a GitHub-sized list carries two base64 PNGs per tool and
decoding them during list rebuilds, on every filter keystroke, cost seconds. A row reads
a finished `NSImage`. One `IconRef` implementation backs both server tile and tool rows so
the pick rule cannot drift. `http(s)` icons stay lazy (they need the network) and are the
only case a tile runs a task; successes are cached per `src` (a cache that could hold nil
could not tell "decoded nothing" from "never tried"). Undecodable pixels leave the slot
empty — never placeholder artwork.

### 7. Threading model

`ServerModel`/`AppModel` are `@MainActor @Observable`; URLSession async I/O runs off-main.
`Connection` is a plain class whose methods run as independent Tasks (a call may stream
while a cancel notification or a server-request rejection goes out), so its mutable state
— negotiated mode, last session header, the in-flight request map, tool schemas — is
serialized behind an `NSLock`, **never held across an `await`**.

Details that were bugs and are now invariants:

- The in-flight requests are a **map id → method**, not a single slot: one slot named the
  wrong request as soon as two overlapped (reloading tools during a call made
  `notifications/cancelled` name the wrong id). Cancel prefers an in-flight `tools/call`.
- In-flight ids are registered **before** the POST and released by a `defer`, so every
  exit path (invalid URL, connect failure, error status) frees the slot.
- URLSession reports task cancellation as `URLError(.cancelled)`/-999, not
  `CancellationError`. Normalizing it matters: without it the Cancel button produced a
  red "Request failed" banner — the plain-JSON (non-SSE) path was exactly that path.
- `ServerModel` re-checks `connection === conn` after every `await` — a disconnect or
  config edit mid-flight must not let a dead connection publish tools or `.ready`.
- Request timeout is URLSession's **inactivity** timeout, so SSE keep-alive comments keep
  long calls alive naturally; the resource timeout is 7 days.

### 8. Era detection must read the body

Spec § Backward Compatibility: on 400/404/405 fall back to `initialize` **only** when the
body is not a recognized modern error. Treating every 400 as "wants a 2025 handshake"
silently downgrades a conformant 2026 server — which is exactly how one real bug
(unnamespaced `_meta` keys) was hiding. `MCPError.modernProtocolSignal` recognizes
`-32020/-32021/-32022`, surfaces `supported` / `requiredCapabilities` in the Log, and
adopts a 2025 version only when the server advertises one.

### 9. Mirrored, not moved (`x-mcp-header`)

Designated parameters are copied into `Mcp-Param-*` headers **and stay in `arguments`** —
servers MUST compare header vs body and answer `-32020` when they disagree, so deleting
the argument (what an earlier version did) breaks every conformant server. Absent/null
parameters get no header; there are no invented sentinels. Non-RFC-9110-safe values use
the spec's `=?base64?{Base64}?=` encoding — including empty strings, since URLSession
drops a header with an empty value and `=?base64??=` round-trips cleanly. Tools whose
annotations break the spec (non-token name, duplicate, non-mirrorable type) are kept
visible with per-tool Log warnings — a conformant client must drop them, a debugger must
show them.

### 10. Session retry, once, never for notifications

A 404 mid-session triggers one automatic re-handshake + retry (`allowSessionRetry:
false` on the retry). Notifications never retry: they have no id to retry, and doing so
resurrected sessions the user had just cancelled. `handshake()` clears the stored session
id first, so a stale/expired header can never be sent into a fresh session.

### 11. Resilient config persistence

`servers.json` (`~/Library/Application Support/Faceless MCP Client/`) is documented as
hand-editable, so the decoder is defensive to the point of paranoia: **every** field
degrades to its default instead of throwing — a throw in one server entry would cost
every server in the file. Timeouts are sanitized to 1–3600 s and finite before they ever
reach URLSession. A file that cannot be parsed at all is moved to `servers.json.bad` and
reported in the sidebar — carrying on with an empty list would let the next save
overwrite a config the app never managed to read; if even the rename fails, persistence
is disabled for the session. Writes are atomic, sorted-keys, pretty-printed. Saves are
debounced (400 ms).

The two sash positions per server (tools-pane width, tools/editor split) ride in the same
file under UUID keys. A sash reports its position every frame of a drag, and writing
observed state re-renders exactly the panes being dragged — a feedback loop that made
window scaling stutter and could nudge a divider on its own. So measurements are parked
in an `@ObservationIgnored` dictionary while dragging, committed once the drag settles
(150 ms debounce), and the file write is debounced on top.

### 12. The transcript: a row cap, never a content cap

600 rows are kept per server. The cap is on **rows**, never on content: a kept row holds
its body whole — nothing is truncated, no body is dropped — so everything still on screen
is copyable and inspectable at full length. (An old 200 KB-per-body cut here was what
made a tool name from the middle of a megabyte `tools/list` invisible.) Timestamps carry
seconds everywhere: `Text(_, style: .time)` showed hour:minute only, which made two lines
seconds apart look simultaneous — the whole point of a log timestamp is to place one line
against the next. Outgoing is `→`, incoming (and errors) `←`, notes `•`.

Header values whose name contains auth/token/key/secret are masked (first 8 chars) in the
Log and in the Server profile; the wire carries them in full.

Every row that moved a body carries its size, on the right of the row and in the copied
line (there, as plain digits — a transcript gets grepped). The count is taken **by the
transport, off the bytes it wrote and read**: the request's `httpBody`, the drained
response body, everything an SSE stream handed over before the answer arrived. Never off
the row's printed detail, which is pretty-printed and therefore a bigger, meaningless
number. `RPCOutcome.bytes` travels on to `CallResult.wireBytes`, which is why the size
above a reply and the size on its `←` row cannot disagree. Two honest absences: an SSE
reply is sized as the whole stream it took (its progress notifications came back over
that reply too), and a call with no body — cancelled, transport failure, or a JSON-RPC
error, which travels as a message rather than as bytes — reports no size rather than an
invented one.

### 13. Cancellation is a first-class outcome

Cancel = task cancellation (the real cancel), plus a best-effort
`notifications/cancelled` on 2025-era sessions. A cancelled call produces a `.cancelled`
CallResult with its own label and log line — never a red failure banner. `resultType`
discriminators, `isError` tool errors, JSON-RPC errors and transport failures are each
distinct outcomes with distinct chrome; none of them is flattened into "failure".

### 14. UI decisions worth explaining

- **The output tab is app-wide state** — switching servers keeps Log/Server/Raw selected;
  it never snaps back. The app opens on **Server** because until something is called it's
  the only tab with content. A reply landing while you sit on the Server profile is
  brought to you (jump to Result); any tab you chose yourself is never stolen by a call.
- **One header, both document tabs.** `CallHeader` is shared by the Result tab and the
  Raw tab: announced icon, wire name, and the call's facts to the right — size of the
  reply, duration, time, outcome, in that order. The two tabs are one call seen at two
  depths, and switching between them must not move the frame you are reading it in.
  Size and duration sit in `monospacedDigit` caption type so consecutive calls line up.
  When there is no result to identify — a bare failure text, a fresh connection's
  profile — Raw shows its surface alone.
- **A picture can leave the window.** Right-click gives Save Image… / Copy Image; a drag
  takes the image out as a file, onto the Desktop or anywhere Finder takes one. Finder
  wants a file rather than a promise it has to come back and ask about, so the bytes are
  staged as one — under the name they should land with, in a temp corner that gets swept
  an hour later — and the staged file is what travels; if even staging fails, the drag
  carries pixels instead of quietly carrying nothing. Everything writes
  `ReplyImage.data`, so the file on disk is byte-identical to what the reply carried,
  named `tool-2.png` with the extension sniffed off the magic numbers: a server that
  calls a JPEG `image/png` reports its own mistake in the Log, but it does not get to
  name your file. The save panel applies no type filter and no forced directory — the
  name arrives right, the location is wherever the user last saved, and calling the file
  `x.bin` remains their privilege.
- **⌘F is routed, not responder-chained.** `performTextFinderAction:` only reached a text
  view when one happened to be first responder — after a toolbar click or tab switch
  nothing was, and Find did nothing. `TextFindRouter` keeps weak references to surfaces
  and aims at one directly: focused surface → last-clicked surface → the visible tab's
  primary surface (focusing it first). Surfaces opt out with `findable: false`; the Log
  and Server tabs are lists of small payloads, not search spaces — the full text of any
  entry is findable where it lives as a document, on Raw.
- **The Find, for whichever surface answers, is deliberate routing, not
  responder-chain luck** — see `TextFindRouter`.
- `NavigationSplitView`'s sidebar-toggle button is removed (`.toolbar(removing:)`) —
  that line is not leftover code; delete it and the button (and its focus-ring and
  title-reflow oddities) returns.
- Empty panes stay empty: no placeholders, no "call a tool to see magic".
- The dynamic form (top-level schema properties; widgets per type) and the raw JSON
  editor are two-way synced; the widgets keep transient editing text so half-typed
  numbers aren't reverted mid-keystroke; on **Call, the JSON text wins**.
- Tool display names resolve in spec priority: top-level `title` → `annotations.title`
  (the GitHub server sets only that one) → wire name. Filter matches all three.
- Behavior chips show only hints **explicitly announced true**. The spec's implied
  defaults (`destructiveHint` is "default true" when absent, etc.) are deliberately not
  inferred — the console shows what was announced, not what was implied; each chip's
  tooltip names the wire key.
- A custom `DraggableVSplit` replaces `VSplitView`, which computes its divider from the
  children's ideal sizes and rebalances it whenever content churns — erratic in a tool
  pane. This one moves only when dragged. The drag uses **global** coordinates: local
  translation gets rebased under the moving handle, which makes it lag behind the cursor.
- `FlowLayout` (a custom `Layout`) wraps content-sized chips; `GridItem(.adaptive)` hands
  every cell the column width, so a capsule around a short word grows past it.
- Printing a schema or a raw payload is snapshot work (`onAppear` / connection-state
  change), never per keystroke — re-printing a schema in a body that re-renders on every
  keystroke is exactly the class of work this app was rebuilt to stop doing.

### 15. Errors are data

`MCPError` is a closed taxonomy (invalidURL / http(+body, +rpc) / rpc / streamEnded /
decoding / transport) whose `description` is written to be useful in the banner:
`HTTP 404 — JSON-RPC -32001: Session not found`, truncation byte counts, quoted bodies.
The same taxonomy feeds the era detector (`looksLikeSessionEra`, `modernProtocolSignal`).

## Testing

### scripts/fake_server.py

A stdlib-only fake MCP server (Python 3.6+) built to exercise exactly the paths this
client cares about.

```
python3 scripts/fake_server.py                    # session-era fake MCP on :8777
python3 scripts/fake_server.py --expire-after 2   # sessions die after 2 calls
python3 scripts/fake_server.py --require-auth tok # 401 without the bearer token
python3 scripts/fake_server.py --stateless        # 2026-07-28, strict, on :8777
python3 scripts/fake_server.py --stateless --require-capability origins:elicit
python3 scripts/fake_server.py --stateless --with-bad-schema
python3 scripts/fake_server.py --stateless --mrtr-tools-list   # MRTR on the first tools/list
```

`--stateless` is a deliberately strict 2026 server: it refuses requests whose
`Mcp-Method`/`Mcp-Name` headers disagree with the body, whose `_meta` uses bare
`protocolVersion` instead of `io.modelcontextprotocol/protocolVersion`, that omit
`clientCapabilities`, or whose `Mcp-Param-*` headers don't match the arguments — i.e. the
exact mistakes that make a client silently downgrade to the 2025 handshake. Its
`tools/list` answers with the full CacheableResult decoration plus
`_meta[io.modelcontextprotocol/serverInfo]`, it implements `server/discover`,
`initialize` comes back `404/-32601`, DELETE/GET are `405`. `--loose` logs the violations
and answers anyway.

Its tools and announced metadata mirror common real-world servers (notably GitHub's):
per-tool `icons[]` (light/dark pair, themeless, undecodable `src`, none), `title` only in
`annotations`, structuredContent, `isError` over HTTP 200, real SSE progress using
`params._meta.progressToken`, an `image` content block generated with the same stdlib PNG
writer (`picture` — the image deck, Save Image… and the drag out), x-mcp-header mirroring
(`deploy`), and MRTR (`need_input`, and optionally the first `tools/list`).

### Test checklist (against the fake server or your own)

1. **Handshake**: Server tab shows negotiated version + session id (session era).
2. **Auto-detect**: Auto on a 2025-era and a 2026-era server; the Log shows which path was taken.
3. **tools/call**: text/image content, `structuredContent`, `isError` styling. With
   `picture` (the fake server generates a PNG with the same stdlib writer its announced
   icons use): right-click **Save Image…** and drag the image onto the Desktop — both
   files must be byte-identical to the block's `data` from Raw once base64-decoded
   (`cmp`), named `picture-1.png`, and **Copy Image** must paste as a picture.
4. **SSE**: streaming progress — live progress text + notification list.
5. **Cancel**: long call → Cancel → Log shows stream closed (+ `notifications/cancelled` for 2025-era).
6. **Session expiry**: restart the server while connected → the next call re-initializes automatically (Log: `session expired … re-initializing`).
7. **Headers**: token in the Authorization field (or any custom header) → masked in the Log, full value on the wire; the dedicated field and the header list edit the same stored entry.
8. **2026 conformance** (`--stateless`): Auto must land on `2026-07-28 · stateless` with no `initialize` in the Log. `deploy` → the Log shows the `Mcp-Param-Region=… / Mcp-Param-Replicas=…` mirror line and the reply confirms the values also arrived in `arguments`. `--require-capability origins:elicit` → logged `-32021` with the capability named, not a downgrade.
9. **MRTR**: `need_input` → flagged `resultType=input_required` instead of a fake success. The flag applies to every method: with `--mrtr-tools-list` the *first* `tools/list` answers `input_required` and the Log must show it (Refresh gets the real list).
10. **Server profile**: identity, capabilities, instructions, raw payload — from `initialize` (session) or `server/discover` / result `_meta` (stateless). The header tile shows the announced icon with the theme pick; no/broken/unreachable icons fall back to the placeholder (status color belongs to the placeholder only). Capability pills wrap in a flow. Output-tab selection sticks across server switches. Long
instructions scroll inside their card and read exactly like a short one (the fake server's
are short, so that last one needs a real server).
11. **Tool icons**: rows and the editor header render announced `icons[]` with the same theme pick; `echo` swaps with the OS appearance, `add` uses the themeless fallback, `boom`'s undecodable `src` leaves an empty slot, the rest reserve alignment slots. Pick + decode happen once per tool, off the main actor.
12. **Tool annotations**: rows show the resolved title (top-level → `annotations.title` → name), filter matches it; compact chips for read-only/destructive, full hint set + raw `annotations` disclosure in the editor.
13. **Sizes**: every `→` row shows the bytes sent and every `←` row the bytes received (tooltip: the exact count), and the header on the Result and Raw tabs repeats the number from the reply's `←` row. With the fake server, `echo`'s request row is the size of the JSON arguments, and `progress` (SSE) shows more on its row than the printed event — the progress notifications arrived over the same reply. A cancelled or failed call shows no size. Finally the folded description: any real-world server has a tool that describes itself in more than 1.6 KB — open its `description` disclosure and the text inside must be dressed exactly like `echo`'s short one standing inline (the fake server's tools are all short, so it needs a real one).

### Unit-testable core

The spec logic is deliberately written as pure/static functions so a test target can
cover it without any UI or network: `SSEParser`, `MCPError.looksLikeSessionEra` /
`modernProtocolSignal`, `Connection.applyDesignatedHeaders` / `encodeHeaderValue` /
`isHeaderSafe` / `designatedHeaderWarnings` / `resultTypeNote`, `JSONValue` round-trip +
printer determinism, `ServerConfig`'s lenient decoder, `AppModel.uuidKeyed`. (No test
target exists yet — this is the first thing to add if the app grows.)

## Known limitations

- No stdio transport — HTTP only. Deprecated 2024 HTTP+SSE (GET stream + `endpoint`
  event) is not supported; the Log flags it if a server still does it.
- No OAuth 2.1 — static bearer tokens and custom headers only. Header values are stored
  in clear text in `servers.json`; this is a dev tool for LAN use.
- Server→client requests are answered `-32601` and logged; MRTR `input_required` is
  flagged but not interactively handled.
- The form covers top-level primitives, enums and booleans; nested objects/arrays and
  exotic schemas (`$ref`, `anyOf`) fall back to single-line JSON fields, and the raw JSON
  editor is the escape hatch for everything.
- Up to 600 transcript rows per server, bodies kept whole — a session of megabyte-sized
  replies can hold hundreds of MB in memory. Restarting the app is the documented fix;
  a byte budget over row bodies is the known future patch.
- Result blocks scroll inside fixed-height boxes rather than unfolding to full page
  height — the deliberate trade that keeps resizing cheap. The whole reply is one
  Raw tab or one Copy away.
- No proxy/env configuration; direct connections only.
- Only one window, one live connection per server.

## Roadmap

- **M3**: interactive server→client requests (sampling/elicitation/MRTR), OAuth 2.1,
  Keychain for secrets, call history/compare, per-call request editor (headers per call).
- **M4**: polish: tabs per tool, transcript filters, export bundle.
- First engineering item: a test target for the pure spec logic listed above.
