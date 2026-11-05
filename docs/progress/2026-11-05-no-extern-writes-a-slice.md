# No kernel extern writes a slice Lyric code holds (#8730, D400)

The dotnet TCP, console-stdin and piped-process kernels no longer hand
`Stream.Read` a `slice[Byte]` held in a field. Their scratch is a host
`MemoryStream` whose backing array is fetched as the argument of the read and
copied out with `.slice(0, n)`, so the reused buffer (#7269) stays and no
Lyric slice binding changes after it exists. The piped-process line buffer
reads its `MemoryStream` backing array by index off `GetBuffer()` instead of
binding it. The JVM unix-socket HTTP reader passes a `ByteBuffer`'s backing
array straight to its sink, and `lyric-mail` wraps attachment bytes in a
read-only `MemoryStream`. docs/14 §10.2 states the rule per target, and
`lyric prove` now reads a slice element as `select` of its elements (docs/15
§5.2).

Verified on dotnet: `process_tests`, `process_piped_bytes_tests`,
`console_stdin_tests`, `tcp_host_tls_tests` (8), `http_server_dotnet_tests`
(32), `json_rpc_stdio_tests` (38), lyric-ws and lyric-mail (81). On the JVM:
`process_tests`, `process_piped_bytes_tests` and the unix-socket HTTP client.
