# 64 — Migrating `lyric-mcp` to MCP spec revision `2026-07-28`

Status: Phase A (§3, stateless core) specced and implemented in D133 —
`--target dotnet` fully tested (54/54 across `lyric-mcp`'s three suites).
Phases B (§4, streamable HTTP), C (§5, Tasks extension), and D (§7,
out of scope) remain open/unbacked. Extends `docs/62-jsonrpc-mcp.md`
(D129), which
shipped `lyric-jsonrpc` + `lyric-mcp` (stdio, protocol revision
`2025-06-18`/`2025-03-26`) as speced. This doc covers the migration to
the `2026-07-28` MCP specification revision — billed upstream as "the
largest protocol revision since it launched" (stateless core,
extensions framework, formal deprecation policy) — and the still-open
`docs/62` streamable-HTTP milestone, updated for what that revision
requires of the HTTP transport.

Link back: this doc is cited from `docs/62`'s status header and open
questions (Q-MCP-002 in particular — see §2 below).

## 1. Motivation

`lyric-mcp` targets `2025-06-18` today (D129). MCP's `2026-07-28`
revision changes the wire protocol in ways that are not backward
compatible at the handshake level: the `initialize`/`initialized`
lifecycle and `Mcp-Session-Id` are removed outright, not deprecated.
Adopting it is not "add a capability," it is "replace the connection
lifecycle" — every existing `Mcp.Server`/`Mcp.Client` caller is affected.

Three reasons to do this now rather than parking `2025-06-18`
indefinitely:

1. **Q-MCP-002 (`docs/62` §9) is resolved by this revision, not by
   anything `lyric-mcp` would build itself.** `2025-06-18`'s answer to
   "how does a long-blocking tool (a permission prompt) behave
   politely" was `notifications/cancelled` + progress tokens — never
   built. `2026-07-28`'s answer is structural: `input_required` results
   let the *server* hand control back to the client mid-call instead of
   blocking the single-threaded dispatch loop. This is the exact shape
   cloud-agents' permission-callback server needs (docs/62 §1, "the
   cloud-agents application needs an MCP server ... permission
   prompts").
2. **The deprecated capabilities (Roots, Sampling, Logging) are exactly
   the ones `lyric-mcp` never implemented** (docs/62 §5.3 "out of
   scope v1": sampling/elicitation, roots). There is nothing to migrate
   off — adopting `2026-07-28` closes three of `docs/62`'s open
   questions (Q-MCP-001 sampling, part of Q-MCP-002) by removing the
   target rather than building toward it.
3. **Streamable HTTP (docs/62 §5.3 milestone 2) was never built.**
   Building it against `2025-06-18`'s session-ful design now would mean
   immediately reworking it for `2026-07-28`'s stateless headers within
   the deprecation window. Building it once, against the current
   revision, is strictly less work.

## 2. Scope and phasing

Four tracks. Each lands as its own PR, same discipline as docs/62 §8.

| Phase | What | Depends on |
|---|---|---|
| **A** | Stateless core: remove `initialize`/`initialized` requirement, `_meta`-carried version/capabilities, `server/discover`, `input_required` multi-round-trip | nothing — stdio only, no new transport |
| **B** | Streamable HTTP transport (`Mcp.Http`): `Mcp-Method`/`Mcp-Name` headers, `ttlMs`/`cacheScope`, W3C trace context | Phase A (stateless core is a prerequisite — HTTP transport built session-ful would need re-doing) |
| **C** | Tasks extension (`Mcp.Tasks`): poll-based `tasks/get`/`tasks/update`/`tasks/cancel` | Phase A |
| **D** | Auth hardening (RFC 9207 `iss` validation, DCR `application_type`, CIMD) | **out of scope of this doc** — see §7 |

Phase D is deliberately not planned here: every one of its SEPs
*hardens* an existing OAuth 2.1 resource-server implementation, and
`lyric-mcp` has never had one (Q-MCP-003, `docs/62` §9, is still fully
open — "OAuth 2.1 resource-server support on streamable HTTP" was never
started). Retrofitting `iss` validation onto authorization code that
doesn't exist isn't meaningful work; building OAuth 2.1 from scratch
for MCP is its own epic, orthogonal to the wire-protocol migration this
doc covers, and belongs in a doc of its own once someone picks it up.
Tracked as the (still open) Q-MCP-003.

## 3. Phase A — stateless core

### 3.1 What changes in `Mcp`

- `protocolVersionLatest` becomes `"2026-07-28"`. `protocolVersionLegacy`
  becomes `"2025-06-18"` (the previous latest is now the fallback the
  same way `2025-03-26` was before it — `isSupportedProtocolVersion`/
  `negotiateProtocolVersion` keep their existing shape, just shift which
  two strings they accept). A peer that only speaks `2025-03-26` is no
  longer accepted in v2 — that's a real, documented break, called out in
  the migration notes (§6).
- New `McpInputRequired` result shape, used by `tools/call`:

  ```lyric
  pub record McpInputRequired {
    inputRequests: JsonValue      // opaque object; caller-defined shape
    requestState: String          // opaque token, echoed back verbatim
  }
  pub union McpToolCallOutcome {
    case ToolResult(result: McpToolResult)
    case InputRequired(value: McpInputRequired)
  }
  ```

  `requestState` is an opaque echo token, not a capability or
  authorization credential: nothing in the protocol or in `Mcp.Server`
  binds it to the peer or session that received it, so a client can
  fabricate one and call `resume` directly without ever having seen the
  original `InputRequired` outcome. A resumable handler that encodes a
  security-sensitive target in `requestState` (the shipped
  `confirm_delete` example does, for illustration) must still perform
  its own authorization check inside `resume` — the round trip is a
  UX/retry pattern, not a security boundary.

  `McpToolHandler.call` gains no new method. A handler that needs
  mid-call input is **not** expressed by widening `call`'s existing
  `Result[McpToolResult, String]` return type to also carry
  `InputRequired` — instead there is a separate companion interface
  `McpResumableToolHandler` with `call` returning
  `Result[McpToolCallOutcome, String]` and a `resume(requestState: in
  String, inputResponses: in JsonValue): Result[McpToolCallOutcome,
  String]`. A resumable tool is registered as its own record
  `McpResumableToolDef` (the same `name`/`description`/`inputSchema`
  fields as `McpToolDef`, but `handler: McpResumableToolHandler`), kept
  in a separate `resumableTools: List[McpResumableToolDef]` list on
  `McpServer` alongside the existing plain `tools: List[McpToolDef]` —
  not a field added to `McpToolDef` itself. This keeps every existing
  `McpToolHandler`/`McpToolDef`/`addTool` implementation (cloud-agents'
  `shim/` included) compiling unchanged; only a tool that actually
  needs the permission-prompt pattern registers via the new
  `addResumableTool`/`McpResumableToolDef` instead.
- `server/discover`: a new zero-params request, answerable at any time
  (no readiness gate — see next bullet), returning the same shape
  `initialize` used to return minus the lifecycle bookkeeping:
  `{serverInfo, capabilities}`.
- **The `ready` gate goes away.** `McpServer.ready` and the
  `serverNotInitialized` rejection path are deleted — every request
  (`tools/call`, `resources/read`, ...) is answerable immediately;
  version/client identity travel in `_meta` on the request object
  itself (`getField(paramsObj, "_meta")`, decoded once per request by a
  shared helper) rather than being pinned once at handshake time. A
  request with no `_meta.protocolVersion` is treated as the latest
  revision (permissive default — the spec has no wire-level version
  mismatch error, per the existing `negotiateProtocolVersion` doc
  comment, and that stays true here).
- `notifications/initialized` is no longer sent/expected — removed from
  `Mcp.Client`.

### 3.2 What changes in `Mcp.Server`

- `handleInitialize` / the `ready` field / `notInitializedCode` are
  deleted.
- New `handleServerDiscover`.
- `handleToolsCall` gains the resumable branch: it first looks up the
  tool name in `resumableTools`; if found there, and the incoming
  params include `requestState` (a well-known params field, not
  `_meta` — this is ordinary MCP-message data, not protocol metadata),
  dispatch to `resumableHandler.resume(...)` instead of
  `resumableHandler.call(...)`; a resumable tool name always takes
  precedence over a same-named entry in the plain `tools` list.
  An `InputRequired` outcome encodes to
  `{resultType: "input_required", inputRequests, requestState}`; a
  `ToolResult` outcome encodes exactly like today's plain result (no
  `resultType` field — v1 compatibility for the common case, matching
  the spec's own framing that `input_required` is additive to the
  existing result shape, not a replacement for it).

### 3.3 What changes in `Mcp.Client`

- `connectTransport`/`connectStdio` drop the `initialize` round-trip
  entirely — constructing an `McpClient` becomes a pure local
  operation (wrap the transport, done). `serverInfo`/`protocolVersion`
  on `McpClient` become populated lazily from the first response that
  carries them, or fetched eagerly via a new `discoverServer` call
  wrapping `server/discover` (recommended, not required, before the
  first `listTools`/`callTool`).
- `callTool` gains a `resumeToolCall(client, requestState, inputResponses)`
  sibling for driving the `input_required` retry loop.

### 3.4 What does not change

- The dispatch model (single-threaded `runLoop`/`call` in
  `lyric-jsonrpc`) is untouched — `input_required` is a data-shape
  change in the MCP layer, not a transport or concurrency change. A
  resumed call is just another ordinary `tools/call` request with a
  different `params` shape; `JsonRpc` never sees the difference.
- Tool-execution-failure-as-`isError`-result stays exactly as is.
- Batch handling stays exactly as is (unaffected by this revision).

## 4. Phase B — streamable HTTP transport (`Mcp.Http`)

Builds `docs/62` §5.3's deferred milestone, updated for `2026-07-28`:

- **Server** (`Mcp.Http.Server`, on `lyric-web`'s `StreamingHandler` +
  `ResponseWriter`, `@cfg(feature = "dotnet")` — inherits the same
  dotnet-only gate `lyric-web`'s streaming support itself carries,
  lyric-lang#5979): a POST route accepting a single JSON-RPC message
  per request body, validating that the `Mcp-Method` header matches the
  body's `"method"` field and `Mcp-Name` matches the tool/resource/
  prompt name inside `params` (reject with `400` on mismatch — the
  spec's stated rationale is gateway-level routing without body
  parsing, so a mismatch is a client bug, not tolerated silently).
  Response is `application/json` for a request that resolves
  synchronously; an `input_required` outcome is still a normal
  `application/json` response (no held-open stream — that's the whole
  point of the stateless redesign, no more GET-opens-an-SSE-stream
  session channel from `2025-06-18`).
- `tools/list`/`resources/list`/`prompts/list`/`resources/read`
  responses gain `ttlMs`/`cacheScope` fields (`"public"` default for
  this v1 — no per-client personalization exists to justify
  `"private"`).
- `_meta.traceparent`/`_meta.tracestate`/`_meta.baggage` are read if
  present and threaded through to `Lyric.Logging`/`OTel.Otlp` context
  if those libraries are in the consuming project (best-effort —
  `Mcp.Http` does not itself depend on `lyric-otel`, it just forwards
  the fields it's handed; a consumer wires up its own OTel exporter).
- **Client** (`Mcp.Http.Client`, on `Std.Http`): one POST per
  request/notification, same header contract as the server side, no
  connection state kept between calls (stateless, per spec) beyond
  whatever base URL / default headers the caller configured once.
- No `Mcp-Session-Id`, no GET/DELETE session-lifecycle routes — those
  were `2025-06-18`-only and are gone in `2026-07-28`.

## 5. Phase C — Tasks extension (`Mcp.Tasks`)

Poll-based, matching the graduated-to-extension shape (not the retired
experimental `2025-11-25` one, which nothing in this ecosystem ever
implemented, so there is no migration burden here beyond building the
current shape once):

```lyric
pub record McpTaskHandle { taskId: String }
pub union McpTaskStatus { case Pending; case Running; case Completed(result: JsonValue); case Failed(message: String); case Cancelled }
pub interface McpTaskBackedTool {
  func startTask(args: in Option[JsonValue]): Result[McpTaskHandle, String]
  func pollTask(taskId: in String): Result[McpTaskStatus, String]
  func cancelTask(taskId: in String): Result[Unit, String]
}
```

`tools/call` against a task-backed tool answers immediately with the
task handle; the client drives `tasks/get`/`tasks/cancel` (server-side
methods on `Mcp.Server`, dispatched the same way `tools/*` is).
`tasks/update` (client-initiated progress push) and `tasks/list`
(removed by spec — unscopeable without sessions) are not modeled;
`tasks/update` needs the server to *initiate* a request to the client,
which is the same "server-to-client interleaved dispatch" gap
Q-MCP-001 already tracks for sampling — so full `tasks/update` support
is blocked on the same prerequisite, not attempted here. v1 of
`Mcp.Tasks` is poll-only (`tasks/get`), which is sufficient for
cloud-agents-shaped long-running-but-not-mid-call-interactive work
(container builds, image pulls) — it does not overlap with Phase A's
`input_required` (that's for *interactive* long-blocking calls;
`Mcp.Tasks` is for *non-interactive* long-running ones).

## 6. Breaking-change notes for existing consumers

`cloud-agents`' `shim/` (the only known consumer, per docs/62 §1) is
affected as follows once it upgrades past whatever `Lyric.Mcp` version
ships Phase A:

- Any code that special-cased `notifications/initialized` timing (none
  known today, but worth grepping for at migration time) goes away.
- Existing `McpToolHandler` implementations need no changes — the
  resumable interface is additive (§3.1).
- The permission-callback tools that actually need multi-round-trip
  behavior (this is the entire reason this track exists — see §1.1)
  are the intended first adopters of `McpResumableToolHandler`; that
  migration is cloud-agents' own follow-up once Phase A ships, tracked
  there, not in this doc.

## 7. Open questions

- Q-MCP-003 (carried over from `docs/62`, still open): OAuth 2.1
  resource-server support — genuinely out of scope here (§2). Whoever
  picks this up should also fold in the `2026-07-28` hardening SEPs
  (RFC 9207 `iss` validation, DCR `application_type`, issuer-bound
  credentials, CIMD) as part of the same design rather than building
  bare OAuth first and hardening it later.
- Q-MCP-004: `Mcp.Tasks`' `tasks/update` (server-initiated progress
  push) is blocked on the same interleaved-dispatch prerequisite as
  Q-MCP-001 (sampling). Whoever unblocks one should check whether it
  unblocks the other.
- Q-MCP-005: MCP Apps (sandboxed-iframe UI extension) has no plausible
  home in a stdio/HTTP JSON-RPC library with no browser runtime of its
  own — flagged so a future reader doesn't wonder why this doc doesn't
  plan it. If `lyric-web`-hosted agent UIs ever want this, it starts as
  its own sketch against `lyric-web`, not `lyric-mcp`.
- Q-MCP-006: JSON Schema 2020-12 tool-schema support needs no library
  change — `McpToolDef.inputSchema` is already an opaque `JsonValue`
  `lyric-mcp` never validates or interprets, just stores and echoes
  (`server.l`'s `encodeToolDef`/`decodeToolInfo`), so `$ref`/`$defs`/
  `oneOf`/`anyOf`/`allOf` pass through today with zero code changes.
  Recorded here only so this fact doesn't get silently re-litigated.
