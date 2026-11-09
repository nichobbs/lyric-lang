# Lyric Standard Library — v1.0 Stability Table

Every public module in `lyric-stdlib/std/` is listed below with its stability
tier at the v1.0 release.  The mechanism is documented in the decision log
(D040).  The table was last walked against the sources on 2026-11-09 (issue
#367); the walk procedure is at the end of this file.

**Rules:**

- `@stable(since="X.Y")` — the public API of this item is covered by Lyric
  SemVer; breaking changes require a major version bump.  The `since` field
  records the first release in which the item was stable.  No release has been
  tagged yet, so every stable item says `since="1.0"`.
- `@experimental` — the API may change in any minor release; callers should
  pin to a specific version.  Missing entirely from the `@stable` enforcement
  boundary.
- A stable `pub` function may not call an `@experimental` item in the same
  package (diagnostic S0001).

`lyric public-api-diff <old.dll> <new.dll>` enforces this boundary: removing
or changing a `@stable` symbol is reported as breaking (exit code 2), while
removing or changing an `@experimental` one is not.  The baseline for the
v1.0 tag is cut as described in `docs/22-distribution-and-tooling.md`
("Cutting the public-API baseline").

---

## Stable at v1.0

Every `pub` item in these modules is annotated `@stable(since="1.0")`, except
the `@experimental` items listed in the last column.  A `pub use` re-export of a
kernel package (`Std.Collections`, `Std.Json`, `Std.Time`, `Std.Uuid`) carries
no annotation; the re-exported kernel surface is not part of the API.

| Module (import path) | Source file | Notes | `@experimental` items |
|---|---|---|---|
| `Std.AnnotationMeta` | `std/annotation_meta.l` | Runtime reader for `config { }` field annotations | |
| `Std.App` | `std/app.l` | Entry-point and signal-handler hooks | |
| `Std.Buffer` | `std/buffer.l` | `buffer[T]` construction and view helpers | |
| `Std.Char` | `std/char.l` | Character classification and conversion | `tryFromInt` |
| `Std.Collections` | `std/collections.l` | List, Map (generic containers) | `mapSize`, `mapIsEmpty` |
| `Std.Console` | `std/console.l` | `println`, `print`, `readLine` | |
| `Std.ConfigOverride` | `std/config_override.l` | Set a `config { }` field from code | |
| `Std.Core` | `std/core.l` | `Option`, `Result`, and combinators | |
| `Std.Core.Proof` | `std/core_proof.l` | Structural-induction axioms for the verifier | |
| `Std.Directory` | `std/directory.l` | Directory listing and creation | |
| `Std.Encoding` | `std/encoding.l` | UTF-8 encode/decode | |
| `Std.Environment` | `std/environment.l` | Environment variable access | `isWindows` |
| `Std.Errors` | `std/errors.l` | `IOError` and common error types | |
| `Std.File` | `std/file.l` | File read/write/exists, `stat` | `listEntries`, `entryKind`, `EntryKind`, `rename`, `realPath`, `setExecutable` |
| `Std.Format` | `std/format.l` | `format1`–`format4` string interpolation helpers | |
| `Std.Hash` | `std/hash.l` | SHA-1, SHA-256 and SHA-512 hex digests | `sha256Digest`, `hmacSha256`, `constantTimeEquals` |
| `Std.Http` | `std/http.l` | HTTP client (`get`, `post`, `put`, `delete`), builder, TLS options | `sendWithTimeoutAsync`, `getWithTimeoutAsync`, `postWithTimeoutAsync` |
| `Std.Iter` | `std/iter.l` | `Iter[T]` iterator protocol | |
| `Std.Json` | `std/json.l` | JSON parse and serialise (`.NET`, `JVM`, and `native`) | `lyricJson*` helpers called by `@generate(Json)` output (`lyricJsonGetInt`, `lyricJsonGetLong`, `lyricJsonGetDouble`, `lyricJsonGetBool`, `lyricJsonGetString`, `lyricJsonGetSubObject`, `lyricJsonIsKind`) |
| `Std.JsonRpc` | `std/json_rpc.l` | JSON-RPC 2.0 peer (D204) | |
| `Std.JsonRpc.Stdio` | `std/json_rpc_stdio.l` | NDJSON and Content-Length stdio framings | |
| `Std.JsonValue` | `std/json_value.l` | Strict RFC 8259 JSON value model, parser and writer (dotnet, JVM) | |
| `Std.Log` | `std/log.l` | Structured logging (`LogLevel`, `log`) | |
| `Std.Math` | `std/math.l` | `abs`, `min`, `max`, `sqrt`, `pow`, `floor`, `ceil`, trig | |
| `Std.Parallel` | `std/parallel.l` | Fork-join `forRange` and `forChunks`, `threadCount` | |
| `Std.Parse` | `std/parse.l` | `parseInt`, `parseFloat`, `parseBool` | |
| `Std.Path` | `std/path.l` | Path join/split/extension | |
| `Std.Process` | `std/process.l` | Child-process launch | |
| `Std.ProcessArgs` | `std/process_args.l` | Command-line argument access | |
| `Std.ProcessCapture` | `std/process_capture.l` | `captureOutput` | |
| `Std.Random` | `std/random.l` | Seeded and shared PRNG (not cryptographic) | |
| `Std.Regex` | `std/regex.l` | Regular expressions | |
| `Std.RegexSafe` | `std/regex_safe.l` | Timeout-bounded regex wrappers | |
| `Std.Rest` | `std/rest.l` | Typed REST client builder | |
| `Std.SecureRandom` | `std/secure_random.l` | Cryptographically secure randomness | |
| `Std.Set` | `std/set.l` | Immutable `Set[T]` | |
| `Std.Sort` | `std/sort.l` | `sort`, `sortBy`, `sortDescending` | `isAscendingInts`, `isAscendingLongs`, `isAscendingStrings` |
| `Std.Stream` | `std/stream.l` | Lazy `Stream[T]` | |
| `Std.String` | `std/string.l` | All string utilities | |
| `Std.Testing` | `std/testing.l` | `assert*` helpers and `@test_module` | |
| `Std.Testing.Mocking` | `std/testing_mocking.l` | `StubCounter`, `@stubbable` helpers | |
| `Std.Testing.Property` | `std/testing_property.l` | Property-based testing (generators, shrinking) | |
| `Std.Testing.Snapshot` | `std/testing_snapshot.l` | Snapshot testing with configurable directory | |
| `Std.Time` | `std/time.l` | `Instant`, `Duration`, `now`, `sleepMillis` | `tryFromEpochMillis`, `tryFromEpochSeconds` |
| `Std.Tls` | `std/tls.l` | PEM certificate and key loading (D128) | |
| `Std.Uuid` | `std/uuid.l` | UUID v4 generation | |
| `Std.Xml` | `std/xml.l` | Pure-Lyric XML 1.0 parser | |
| `Std.Yaml` | `std/yaml.l` | Pure-Lyric YAML 1.2 / JSON parser | |

---

## Experimental at v1.0

Every `pub` item in these modules is `@experimental`.  They ship with the
standard library but are outside the SemVer boundary.

| Module (import path) | Source file | Notes |
|---|---|---|
| `Std.Bench` | `std/bench.l` | `lyric bench` support |
| `Std.BuildInfo` | `std/buildinfo.l` | `BuildInfo` record; the compiler synthesises `buildInfo()` (docs/60 §9.2) |
| `Std.Collections.Persistent` | `std/collections_persistent.l` | Persistent list and map |
| `Std.Coverage` | `std/coverage.l` | `lyric test --coverage` support |
| `Std.Ed25519` | `std/ed25519.l` | Pure-Lyric Ed25519 (D248) |
| `Std.Ffi` | `std/ffi.l` | C memory and C strings for `@library` bindings |
| `Std.HttpClientWire` | `std/http_client_wire.l` | HTTP/1.1 client response parsing |
| `Std.HttpEngine` | `std/http_engine.l` | Sans-IO HTTP engine (docs/61) |
| `Std.HttpEngine.H2Conn` | `std/http_h2conn.l` | HTTP/2 connection state machine |
| `Std.HttpEngine.H2Frame` | `std/http_h2frame.l` | HTTP/2 frame codec |
| `Std.HttpEngine.Hpack` | `std/http_hpack.l` | HPACK codec |
| `Std.Linalg` | `std/linalg.l` | `Vec2`–`Vec4`, `Quat`, `Mat3`, `Mat4`, `Rgba8` (docs/67) |
| `Std.Plugin` | `std/plugin.l` | Plugin host (docs/69) |
| `Std.Plugin.Trusted` | `std/plugin_trusted.l` | Trusted in-process plugin mode |
| `Std.PluginCatalogue` | `std/plugin_catalogue.l` | Per-application plugin catalogues |
| `Std.PluginSign` | `std/plugin_sign.l` | Plugin artifact signatures |
| `Std.PluginWasm` | `std/plugin_wasm.l` | WIT-typed component plugins |
| `Std.Zip` | `std/zip.l` | Pure-Lyric zip and DEFLATE |

---

## Kernel boundary (`lyric-stdlib/std/_kernel/`, `_kernel_jvm/`, `_kernel_native/`, `_kernel_wasm_module/`)

Kernel files are internal implementation detail and are **not** part of the
public API.  Callers import the top-level `Std.*` modules, which wrap the
kernel files.  Kernel symbols carry no stability guarantee.

- `_kernel/` holds the .NET kernels (plus a few target-neutral files:
  `jvm.l`, `jvm_exception.l`, `task.l`).  Each `*_host.l` file is the extern
  boundary of the `Std.*` module of the same name (`Std.<Name>Host`).
- `_kernel_jvm/`, `_kernel_native/` and `_kernel_wasm_module/` declare the same
  package as their `_kernel/` twin and win by basename on their target
  (D-N-014).
- The directory README (`_kernel/README.md`) is the authority on the
  extern-declaration budget; this file does not list kernel files one by one.

Four packages that live in the kernel directory are imported directly by
programs and carry **no** `@stable` or `@experimental` annotation:
`Std.Task` (`_kernel/task.l`), `Std.HttpServer` (`_kernel/http_server.l`),
`Std.TcpHost` (`_kernel/tcp_host.l`) and `Std.Jvm` (`_kernel/jvm.l`).  Their
tier is an open decision for the project lead (docs/12, "Open decisions"); until
it is made they are outside the SemVer boundary.

---

## Walk procedure

To re-check this table: for every `lyric-stdlib/std/*.l`, read the `package`
line, then confirm each column-0 `pub` item (other than `pub use`) has a
`@stable(since="1.0")` or `@experimental` line directly above it (doc comments
and `@pure`/`@io` lines may sit between).  A module whose items are all
`@stable` belongs in the first table, all `@experimental` in the second; mixed
modules go in the first table with the experimental items named.  Every file
in `std/` must be listed exactly once.
