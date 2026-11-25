# lyric-grpc: the pure-Lyric client on `H2Client` (docs/72 slice 6)

Slice 6 of `docs/72-h2-client-role-plan.md`. Decision: D802.

## What shipped

- `Grpc.Wire` (`lyric-grpc/src/wire.l`): message framing and reassembly, gzip, `grpc-timeout`, the status mapping tables. The D287 server now frames responses with it.
- `Grpc.Client` (`lyric-grpc/src/client.l`): unary and server-streaming calls over `Std.HttpEngine.H2Client`, a pooled channel (one connection by default, `maxConnections`, FIFO queue past `MAX_CONCURRENT_STREAMS`, GOAWAY replacement, idle close, reconnect backoff), one transparent retry of unprocessed streams, `Grpc.openChannelWith(address, ChannelOptions)`, `Grpc.withCompression`. It is the default client on dotnet and the JVM; the `legacy-client` feature keeps the SDK kernels selectable until slice 10.
- Tests: `wire_tests.l` (13, pure), `client_h2_tests.l` (32, scripted `H2Conn` peer, target neutral: Trailers-Only, non-200, bad content type, status tables, RST codes, messages above the windows, receive limit, gzip bomb, deadline, backoff, 7 calls against `MAX_CONCURRENT_STREAMS = 2`, `maxConnections`, GOAWAY mid-stream, transparent retry, idle close, close with calls in flight, TLS with a pinned CA). The existing `client_dotnet_tests.l`, `client_jvm_tests.l` and `server_tests.l` run unchanged against the new client (dotnet: pure-Lyric peer and D287 server; JVM: grpc-java server).

## Not done (slice 6 is the client half)

Native (slice 7), the pure-Lyric JVM server and server-side compression (slice 8), client and bidi streaming (slice 9), removing `Grpc.Net.Client`, `Grpc.AspNetCore` and grpc-java from the manifest (slice 10). `docs/37` and the manifest SDK sections change in slice 10.

## Verification

Container without Docker; toolchain `cp -r /home/user/tc-72-5 /home/user/tc-72-s6` (the stdlib bundle was already rebuilt from the tree for slice 5 and no stdlib file changed here), Maven and NuGet restore worked (`lyric restore --manifest lyric-grpc/lyric.toml`).

```
source /home/user/tc-72-s6/env.sh
$LYRIC restore --manifest lyric-grpc/lyric.toml
$LYRIC test --manifest lyric-grpc/lyric.toml                                                       # dotnet
env -u JAVA_TOOL_OPTIONS $LYRIC test --manifest lyric-grpc/lyric.toml --target jvm --no-default-features --features jvm
$LYRIC test --manifest lyric-grpc/lyric.toml --no-default-features --features dotnet,legacy-client
env -u JAVA_TOOL_OPTIONS $LYRIC test --manifest lyric-grpc/lyric.toml --target jvm --no-default-features --features jvm,legacy-client
```

| suite | dotnet | JVM | dotnet legacy | JVM legacy |
|---|---|---|---|---|
| `grpc_types_tests` | 25/25 | 25/25 | 25/25 | 25/25 |
| `client_dotnet_tests` / `client_jvm_tests` (pure client) | 12/12 | 12/12 | 12/12 (SDK) | 12/12 (SDK) |
| `server_tests` | 13/13 | 13/13 | 13/13 | 13/13 |
| `wire_tests` (new) | 13/13 | 13/13 | 13/13 | 13/13 |
| `client_h2_tests` (new) | 32/32 | 32/32 | gated off | gated off |
| `server_dotnet_tests`, `rate_limit*`, `channel_lifecycle`, `security_aspect_weaving` | pass | pass | pass | pass |
