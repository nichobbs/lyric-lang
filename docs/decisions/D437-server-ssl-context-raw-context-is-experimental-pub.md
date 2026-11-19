# D437 - `ServerSslContext.rawContext` is `@experimental pub` so `lyric-web` can call it (docs/70 phase 3a, #8613)

**Status:** shipped; a stdlib API addition, not a language change. Approved by the coordinator.

## Context

`Web.Kernel.Runtime.serveTls` (`lyric-web`, the Undertow kernel) builds its `SSLContext` from `Std.HttpServer`'s `serverSslContextFromConfig` and `serverSslContextFromConfigMtls`, both `pub`, and then reads the context out with `ServerSslContext.rawContext`, which was `internal`. `internal` reaches the packages of one project, and `lyric-web` is a separate project, so the call crossed a visibility boundary. It built only because the JVM backend guesses an untyped call, and the type checker recorded no callee for it (the "call the checker did not resolve" kind at `web_kernel.l` 425). With D432, which hides a stdlib package's `internal` items from every importer that is not itself stdlib, the bypass is explicit.

## Decision

`ServerSslContext.rawContext` is `@experimental pub`, beside the `@experimental pub` `serverSslContextFromConfigMtls` that exists for `lyric-web`. It stays in the JVM kernel (`std/_kernel_jvm/http_server.l`) only, as the `internal` function was: no dotnet or native twin. It is outside the stable surface (the API may change in a minor release).

The long-term plan is a `lyric-web` constructor path that needs no raw context: docs/73's pure-Lyric server over `Std.HttpEngine` and `Std.TcpHost` removes the accessor, and with it this decision.

## Results

`Web.Kernel.Runtime::serveTls` resolves its two `rawContext` calls. `tls_server_jvm_tests.l` and `Std.TcpHost`'s JVM kernel call it as before.
