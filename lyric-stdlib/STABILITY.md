# Lyric Standard Library — v1.0 Stability Table

Every module in `stdlib/std/` is listed below with its stability tier at the
v1.0 release.  The mechanism is documented in the decision log (D040).

**Rules:**

- `@stable(since="X.Y")` — the public API of this item is covered by Lyric
  SemVer; breaking changes require a major version bump.  The `since` field
  records the first release in which the item was stable.
- `@experimental` — the API may change in any minor release; callers should
  pin to a specific version.  Missing entirely from the `@stable` enforcement
  boundary.

`lyric public-api-diff` enforces this boundary: a PR that removes or changes
a `@stable` symbol without a corresponding major-version bump is rejected by
CI.

---

## Stable at v1.0

All items in these modules are annotated `@stable(since="1.0")` unless noted.

| Module (import path) | Source file | Notes |
|---|---|---|
| `Std.App` | `std/app.l` | Entry-point and signal-handler hooks |
| `Std.Char` | `std/char.l` | Character classification and conversion |
| `Std.Collections` | `std/collections.l` | List, Map (generic containers) |
| `Std.Console` | `std/console.l` | `println`, `print`, `readLine` |
| `Std.Core` | `std/core.l` | `Option`, `Result`, and combinators |
| `Std.Core.Proof` | `std/core_proof.l` | Structural-induction axioms for the verifier |
| `Std.Directory` | `std/directory.l` | Directory listing and creation |
| `Std.Encoding` | `std/encoding.l` | UTF-8 encode/decode |
| `Std.Environment` | `std/environment.l` | Environment variable access |
| `Std.Errors` | `std/errors.l` | `IOError` and common error types |
| `Std.File` | `std/file.l` | File read/write/exists |
| `Std.Format` | `std/format.l` | `format1`–`format4` string interpolation helpers |
| `Std.Http` | `std/http.l` | HTTP client (`get`, `post`, `put`, `delete`) |
| `Std.Iter` | `std/iter.l` | `Iter[T]` iterator protocol |
| `Std.Json` | `std/json.l` | JSON parse and serialise (.NET only; `@stable`) |
| `Std.Log` | `std/log.l` | Structured logging (`LogLevel`, `log`) |
| `Std.Math` | `std/math.l` | `abs`, `min`, `max`, `sqrt`, `pow`, `floor`, `ceil`, trig |
| `Std.Parse` | `std/parse.l` | `parseInt`, `parseFloat`, `parseBool` |
| `Std.Path` | `std/path.l` | Path join/split/extension |
| `Std.Process` | `std/process.l` | Child-process launch |
| `Std.ProcessCapture` | `std/process_capture.l` | `captureOutput` |
| `Std.Rest` | `std/rest.l` | Typed REST client builder |
| `Std.Set` | `std/set.l` | Immutable `Set[T]` |
| `Std.Sort` | `std/sort.l` | `sort`, `sortBy`, `sortDescending` |
| `Std.Stream` | `std/stream.l` | Lazy `Stream[T]` |
| `Std.String` | `std/string.l` | All string utilities |
| `Std.Testing` | `std/testing.l` | `assert*` helpers and `@test_module` |
| `Std.Testing.Mocking` | `std/testing_mocking.l` | `StubCounter`, `@stubbable` helpers |
| `Std.Testing.Property` | `std/testing_property.l` | Property-based testing (generators, shrinking) |
| `Std.Testing.Snapshot` | `std/testing_snapshot.l` | Snapshot testing with configurable directory |
| `Std.Time` | `std/time.l` | `Instant`, `Duration`, `now` |
| `Std.Uuid` | `std/uuid.l` | UUID v4 generation |
| `Std.Xml` | `std/xml.l` | Pure-Lyric XML 1.0 parser (`@stable(since="0.1")`) |
| `Std.Yaml` | `std/yaml.l` | Pure-Lyric YAML 1.2 / JSON parser (`@stable(since="0.1")`) |

---

## Kernel boundary (`stdlib/std/_kernel/`)

Kernel files are internal implementation detail and are **not** part of the
public API.  Callers import the top-level `Std.*` modules, which shadow the
kernel files.  Kernel symbols carry no stability guarantee.

| Kernel file | Platform | Purpose |
|---|---|---|
| `_kernel/char_host.l` | .NET | BCL `System.Char` externs |
| `_kernel/collections_host.l` | .NET | BCL `List<T>` / `Dictionary<K,V>` externs |
| `_kernel/encoding_host.l` | .NET | BCL UTF-8 encoding externs |
| `_kernel/environment_host.l` | .NET | `System.Environment` externs |
| `_kernel/file_host.l` | .NET | `System.IO.File` externs |
| `_kernel/format_host.l` | .NET | `String.Format` externs |
| `_kernel/http_host.l` | .NET | `System.Net.Http` externs |
| `_kernel/http_server.l` | .NET | HTTP server listener externs |
| `_kernel/io.l` | .NET | Core I/O externs (`println`, `readLine`) |
| `_kernel/json_host.l` | .NET | `System.Text.Json` externs |
| `_kernel/jvm.l` | JVM | `Std.Jvm` package (`catch` intrinsic) |
| `_kernel/jvm_exception.l` | JVM | `JvmException` extern type and helpers |
| `_kernel/log_host.l` | .NET | Logging externs |
| `_kernel/math_host.l` | .NET | `System.Math` externs |
| `_kernel/parse_host.l` | .NET | `int.TryParse` / `double.TryParse` externs |
| `_kernel/process_capture_host.l` | .NET | Process capture externs |
| `_kernel/process_host.l` | .NET | `System.Diagnostics.Process` externs |
| `_kernel/random.l` | .NET | `System.Random` externs |
| `_kernel/regex.l` | .NET | `System.Text.RegularExpressions.Regex` externs |
| `_kernel/task.l` | .NET | `System.Threading.Tasks.Task` async externs |
| `_kernel/testing_mocking.l` | JVM | `StubCounter` JVM counterpart |
| `_kernel/time_host.l` | .NET | `DateTimeOffset` / `TimeSpan` externs |
| `_kernel/unicode_host.l` | .NET | Unicode normalisation externs |
| `_kernel/uuid_host.l` | .NET | `System.Guid` externs |
| `_kernel/verifier_env_host.l` | .NET | Verifier environment externs |

