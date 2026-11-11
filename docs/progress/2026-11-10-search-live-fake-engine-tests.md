# lyric-search tested end to end against a fake engine; the reported `bodyText` crash does not reproduce (#8940)

The lyric-search README recorded three compiler defects (cross-package `HttpClient.send`
inside an `async func`, an `async func` awaiting a `SearchClient` call throwing
`InvalidProgramException`, and `HttpResponse.bodyText` throwing an uncatchable
`MissingMethodException`) and a phantom JVM `Std.Http` kernel. Re-checked on `main`: none
reproduces. `lyric-search/tests/search_live_tests.l` (wired into `lyric.toml`) serves a fake
Elasticsearch or Meilisearch engine from `Std.HttpServer` on the loopback interface (a
`Task.Run` worker on dotnet, `spawn` in a `scope` on the JVM) and drives `connect`,
`createIndex`, `index`, `indexBatch`, `search`, `suggest`, `exists`, `delete` and
`deleteIndex` through it, reading every response body with `HttpResponse.bodyText` from outside
`Std.Http`, plus an `async func` awaiting a `SearchClient` call. The fake answers only the
request the real engine would accept (method, path, auth header, body fields), and 401, 404 and
500 responses reach the caller as `SearchError` with the operation code and status. It passes
for both backends on `--target dotnet` and `--target jvm`. No compiler or stdlib change was
needed: the README, `search.l` comments, chapter 29, docs/12, docs/71 (Q-ECO-003 resolved:
search passes on the JVM) and the v1.0 release notes were stale and are corrected. Neither
backend has been driven against a real cluster, so the library stays `experimental`.
