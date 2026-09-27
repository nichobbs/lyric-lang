# D-progress-996 — Sealed MCP `requestState`, HMAC in `Std.Hash`, JSON-RPC contracts

**Status:** shipped

Closes the remaining items of #7245. Framing limits and tool-name
validation shipped earlier in #7290.

## Problem

- **`requestState` is forgeable.** A resumable MCP tool's
  `requestState` passes through the peer and back. `Mcp.Server` routes any
  `tools/call` that carries one to `resume`, so a peer can fabricate,
  alter or reuse a token and skip `call` entirely. The library documented
  the risk but gave handlers no way to check a token, and the stdlib had
  no MAC primitive to build one with.
- **The client decoder accepted malformed results.** It turned an
  `input_required` result without a `requestState` into `""`.
- **`lyric-jsonrpc` gaps:**
  - It accepted any outbound method name.
  - It let handlers answer with reserved protocol error codes.
  - It truncated an untrusted error code with `.toInt()`.
  - It sent handler panic messages to the peer.
  - It counted JSON depth twice per level, so the effective limit was
    about half the configured one.
  - Inbound batches and the queue that `call` fills while it waits were
    both unbounded.

## Decision

- **`Std.Hash`** gains three `@experimental` functions:
  - `sha256Digest`, the raw 32-byte digest;
  - `hmacSha256(key, message)`, RFC 2104 in pure Lyric over the existing
    SHA-256 kernel, so no new extern is needed;
  - `constantTimeEquals(a, b)`.

  The RFC 4231 vectors run on dotnet and, via a new CI step, on the JVM.
- **`Mcp` changes:**
  - `sealRequestState(key, toolName, payload, expiresAtEpochMillis)` issues
    `v1.<base64 payload>.<expiry>.<hex tag>`. The tag covers a domain
    string, the length-prefixed tool name, the expiry and the encoded
    payload.
  - `openRequestState(key, toolName, token, nowEpochMillis)` checks the
    tag in constant time before it checks the expiry. Only then does it
    return the payload.
  - Keys must be at least 32 bytes (a precondition).
  - The payload is authenticated but not encrypted.
  - Replay of a live token by the same peer is left to the handler (a
    consumed-token set), because stateless MCP gives the library nowhere
    to keep one.

  Sealing is a helper, not something the dispatcher enforces, because the
  key and the payload's meaning belong to the tool.
- **`McpInputRequired`** carries
  `invariant: requestState.length in 1..maxRequestStateLength` (8192).
  The server answers `-32602` for an out-of-range `requestState` before
  calling `resume`.
- **`decodeToolCallOutcome`** now returns
  `Result[McpToolCallOutcome, String]`. A missing, non-string, empty or
  oversized state is `Err`, and the client surfaces that as a failed call.
- **Other `Mcp` contracts:**
  - `negotiateProtocolVersion` gets `ensures: isSupportedProtocolVersion(result)`.
  - `newServer` and `encodeInitializeParams` require a non-empty own name.
  - `McpImplementation` itself takes no invariant. A peer's decoded
    `clientInfo`/`serverInfo` may be missing on legacy peers, and the
    decoders stay lenient for that input only.
- **`JsonRpc` changes:**
  - `call`/`notify` require `isValidOutboundMethod`: non-empty and not
    `rpc.` (§4).
  - New `applicationError(code, ...)` requires a code outside
    -32768..-32000.
  - A decoded error code outside the `Int` range becomes `internalError`.
  - Handler panics answer a bare `"Internal error"`.
  - `maxBatchSize` (1024) rejects an oversized batch whole with one
    `-32600`.
  - `maxPendingMessages` (4096) fails the waiting `call` instead of growing
    the queue. Queued messages stay queued for `runLoop`.
- **`JsonRpc.Json`:**
  - Depth now counts once per container.
  - `parseValueWithDepthLimit` requires `maxDepth` in 1..1024.

`call` still has no deadline. `RpcTransport.receive` blocks and exposes no
timeout, so a deadline belongs to the transport (#7451). The native
backend cannot yet compile `hash_tests.l` (#7452). That failure predates
this change.
