# 2026-11-12 - lyric-ecosystem: first out-of-tree backends (docs/71 phase 4)

`nichobbs/lyric-ecosystem` has its workspace, CI and first six packages (lyric-ecosystem#3). Each backend implements a `lyric-lang` interface, re-exports it, and runs that interface's `Testing.Conformance` suite on every target it claims.

| Package | Interface | Targets | Implementation |
|---|---|---|---|
| `Lyric.Storage.S3` | `Storage.StorageBucket` | dotnet, jvm | pure Lyric, AWS Signature V4 over `Std.Http` |
| `Lyric.Jobs.Quartz` | `Jobs.JobScheduler` | jvm | Quartz 2.5.2 through Maven and auto-FFI; Lyric records implement `org.quartz.Job` and `JobFactory`, so registered `JobHandler`s run on Quartz worker threads |
| `Lyric.Redis` | client | dotnet, jvm | pure Lyric RESP2/RESP3 |
| `Lyric.Cache.Redis` | `Cache.CacheStore` | dotnet, jvm | on `Lyric.Redis` |
| `Lyric.Session.Redis` | `Session.SessionStore` | dotnet, jvm | on `Lyric.Redis`, one `EVAL` per read-modify-write |
| `Lyric.Mq.ActiveMq` | `Mq.MessageQueue`, `Mq.QueueConsumer` | dotnet, jvm | pure Lyric STOMP 1.2 |

**How the repository builds.** Git dependencies are restored but not linked (#9037) and the 0.7.12 release predates the conformance suites, so the packages declare the interface packages as `{ workspace = true }` and the root `[workspace.overrides]` resolves them against a `lyric-lang` checkout at the commit in `.lyric-lang-rev`; CI builds the compiler from that commit. The registry route (docs/39) replaces this once a release carries the suites.

**Verification.** Its CI runs the hermetic suites of every package on the targets it claims, and integration suites against a Redis service container, an ActiveMQ Classic broker and a MinIO server, on dotnet and the JVM.

**Stdlib change it needed.** `Std.Http.withBytesBody`, `HttpResponse.headerNames` and `Std.HttpServer.requestBodyBytes` (#9047, `2026-11-12-http-bytes-body.md`).

**Compiler and stdlib issues found** (each linked from the affected package's README): #9037 git dependencies not linked and foreign-workspace transitives dropped; #9038 `impl` for an opaque type; #9039 JVM slice literal inside `Ok(...)`; #9040 workspace overrides depend on the working directory; #9042 `Std.TcpHost` has no JVM kernel; #9043 inherited interface `requires:` across packages (J008 on JVM, unenforced on dotnet); #9044 `for` over a slice literal of `String` fields, `Bug.typeName` on JVM; #9048 `Std.HttpServer` and HEAD; #9049 JVM `byte[]` passed as `slice[Byte]`.

The book's chapter 29 has a "Backends in lyric-ecosystem" section and matrix.
