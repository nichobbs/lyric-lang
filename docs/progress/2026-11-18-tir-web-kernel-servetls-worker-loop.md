# docs/70 phase 3a: the Web kernel's serveTls and worker loop (D437, D438)

`ServerSslContext.rawContext` is now `@experimental pub` in the JVM `Std.HttpServer` kernel so `lyric-web`'s `serveTls` calls a published accessor instead of an `internal` one across a project boundary (D437). The builder types the untyped `Future` result of `ExecutorService.submit` as the host class (D438), so `startWorkerLoop` builds. `jvm_host_kernel_shapes` gains the `submit` shape.

The `lyric-ws` JVM kernel's three extern-interface methods (`handleEvent`, `handleRequest`, `onConnect`) declare the host results they bind (D436), so all 84 `Ws.Kernel.Jvm` bodies build with 0 I0003.

`StringBuilder.append` and its bridge methods bind the receiver's own class, and a `Unit` function discards its last value, so `Std.StringHost` builds 9 of 9 (D439).
