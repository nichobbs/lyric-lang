# Native HTTP server: bulk append for request bodies (#7269)

The native `Std.HttpServer` kernel accumulated each request body chunk one
byte at a time, and every byte was a separate `lyric_list_push` runtime call.
`lyric-rt` now exports `lyric_list_append_all(dst, src)`, which appends a whole
list with one grow and one `memcpy` (retaining elements when the list owns
references). The kernel's `appendBytes` calls it through an `extern func`, so
a chunk costs one runtime call.

`lyric-rt`'s `test_list_append_all` covers byte order and values, an empty
source, appending a list to itself, and reference retention. It is also clean
under AddressSanitizer. `llvm_http_server_self_test.l` exercises the path end
to end with a POST body.

The dotnet kernel still appends per byte. Since #7340 removed the boxing, the
remaining cost is a constant factor, and a bulk `List<T>.AddRange` binding is
blocked on #7422.
