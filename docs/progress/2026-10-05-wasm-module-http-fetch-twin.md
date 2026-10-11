# wasm32 module: fetch-backed Std.Http (docs/35 Q-JS-008)

The module shape compiles `Std.Http` against `_kernel_wasm_module/http_host.l`, a twin of
the native kernel that sends requests through one promise host import, `std.http.fetch`
(D-progress-1049). The glue's default implementation uses the host's global `fetch`, and
`options.imports['std.http'].fetch` replaces it. TLS options and Unix sockets fail at request
time with a typed `ConnectionFailed`. Tests: a node-driven module suite with a stubbed global
`fetch` (GET, POST, JSON body and custom header, 404, network failure, oversized body, hidden
redirect, TLS and Unix-socket refusal with no `fetch` call, the override, the `.d.ts`).
