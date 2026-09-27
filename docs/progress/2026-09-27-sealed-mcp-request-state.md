# 2026-09-27 — Sealed MCP request state, HMAC-SHA-256, JSON-RPC contracts

D-progress-996, #7245.

- **`Std.Hash`** adds `sha256Digest`, `hmacSha256` and
  `constantTimeEquals`. It is pure Lyric over the existing SHA-256 kernel
  and is checked against the RFC 4231 vectors on dotnet and the JVM.
- **`lyric-mcp`:**
  - `sealRequestState`/`openRequestState` let a resumable tool issue a
    `requestState` bound to its name and a deadline, and reject forged,
    altered, cross-tool or expired tokens.
  - `requestState` is limited to 1..8192 characters on every path.
  - The client decoder returns `Err` for a malformed `input_required`
    result instead of inventing `""`.
- **`lyric-jsonrpc`:**
  - Outbound method names are validated.
  - `applicationError` keeps application codes out of the reserved range.
  - Wide error codes are no longer truncated.
  - Panic messages stay local.
  - Batch size and the `call` wait queue are bounded.
  - JSON depth is counted once per container.
