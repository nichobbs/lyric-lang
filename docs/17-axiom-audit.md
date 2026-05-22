# 17 — Axiom Audit

Every `@axiom`-annotated declaration in the Lyric standard library
kernel (`lyric-stdlib/std/_kernel/*.l`).  This document is the authoritative
list.  Each entry records:

- **What** the axiom claims (the contract it asserts without proof).
- **Why** it cannot be proved inside Lyric (the BCL gap, performance
  concern, or decidability limit).
- **What callers must uphold** — the invariants a calling package
  must establish before it can rely on the axiom's postcondition
  soundly.
- **Review status** — whether the axiom has been independently
  reviewed and is considered stable.

The proof system uses every `@axiom` declaration as a *trusted fact*;
there is no proof obligation generated for its body.  This makes
axioms the only source of unverified assumptions in a
`@proof_required` call graph.  Per
`docs/15-phase-4-proof-plan.md` §3.2:

> The axiom whitelist is the entire trust boundary between Lyric
> and the host runtime.  Every axiom must have a rationale, a reviewer,
> and a scope limit.

---

## 1. How to read this document

Kernel files use *package-level* `@axiom` annotations — a single claim
covers every `@externTarget`-declared function in that file.  The format
for each entry is:

```
### `Std.<HostPackage>` — `lyric-stdlib/std/_kernel/<file>.l`

@axiom("<claim>")

**BCL surface**: Which .NET namespaces / types are covered.
**Gap**: Why the claim cannot be proved inside Lyric.
**Caller obligation**: What the caller must ensure.
**Review**: Stable / Under review / Provisional.
```

Only files under `lyric-stdlib/std/_kernel/` may contain `@externTarget` or
`extern type` declarations (per `docs/14-native-stdlib-plan.md`
Decision F).  A new `@axiom` always goes in a new or existing kernel
file.

---

## 2. I/O

### `Std.IO` — `lyric-stdlib/std/_kernel/io.l`

```
@axiom("System.Console and System.IO operations conform to their documented .NET contracts")
```

**BCL surface**: `System.Console` (write, writeLine, errorWriteLine,
readLine) and `System.IO` (File static helpers, Directory static
helpers, Path static helpers).

**Gap**: Console I/O and file I/O have observable side-effects and
depend on OS state that cannot be modelled in first-order logic without
an explicit I/O monad (out of scope for M4.x).  Path helpers are pure
but involve host-OS string conventions (Windows vs. POSIX) that the
prover does not model.

**Caller obligation**: None for the Console write path (postcondition
is `Unit`).  For the file-read/write operations, callers must ensure
`path.length > 0` (enforced by the kernel's own `requires:` clauses).

**Review**: Stable.

---

### `Std.ConsoleHost` — `lyric-stdlib/std/_kernel/console_host.l`

```
@axiom("System.Console operations conform to their documented .NET contracts")
```

**BCL surface**: `System.Console` (Read, Write, WriteLine, ReadLine, In, Out,
Error), backing `Std.Console`.

**Gap**: Console I/O has observable side-effects and depends on process-level
shared file descriptors that cannot be modelled in first-order logic without an
I/O monad.

**Caller obligation**: None for the write path (postcondition is `Unit`).
`ReadLine` may return `null` on EOF; the kernel converts this to an empty
string.

**Review**: Stable.

---

## 3. Collections

### `Std.CollectionsHost` — `lyric-stdlib/std/_kernel/collections_host.l`

```
@axiom("System.Collections.Generic.List / Dictionary conform to their documented .NET contracts")
```

**BCL surface**: `System.Collections.Generic.List<T>` (backed by
`List[T]` in Lyric), `System.Collections.Generic.Dictionary<K,V>`
(backed by `Map[K,V]`), and `System.Collections.Generic.HashSet<T>`
(backed by `Set[T]`).

**Gap**: Mutation semantics of BCL generic collections (resizing,
rehashing, iteration invalidation, `Dictionary.TryGetValue` `out`-param
write) require heap modelling that is outside first-order scope.
Complexity guarantees (O(1) amortised) cannot be expressed as Lyric
contracts.

**Caller obligation**: The usual BCL preconditions — e.g., `i >= 0
and i < list.count` before index access.  The `requires:` on kernel
functions capture only the minimally checkable subset; callers in
`@proof_required` code must establish range bounds through the type
system or explicit contracts.

**Review**: Stable.

---

## 4. Math and parsing

### `Std.MathHost` — `lyric-stdlib/std/_kernel/math_host.l`

```
@axiom("System.Math and System.Double operations conform to their documented .NET / IEEE 754 contracts")
```

**BCL surface**: `System.Math` (abs, min, max, floor, ceiling, round,
sqrt, pow, log, sin, cos, tan, and related) and `System.Double` (NaN,
infinity, IsNaN, IsInfinity).

**Gap**: IEEE 754 floating-point semantics involve rounding modes,
NaN propagation, and underflow/overflow behaviour that are not
expressible in the decidable fragment.  Integer variants (Math.Abs on
Int) have the two's-complement overflow corner case at `Int.min` that
the prover cannot discharge without arithmetic overflow support.

**Caller obligation**: For `Math.Abs(int)`, the caller must ensure
`x > Int.min` (two's-complement overflow otherwise).  Floating-point
callers should be aware that `NaN != NaN` (IEEE semantics) and that
the prover treats `NaN` as an uninterpreted value.

**Review**: Stable.

### `Std.ParseHost` — `lyric-stdlib/std/_kernel/parse_host.l`

```
@axiom("System.Double/Boolean.TryParse conform to their documented .NET contracts")
```

**BCL surface**: `System.Double.TryParse`, `System.Boolean.TryParse` —
each invoked via the `out`-param FFI pattern.  `Int32.TryParse` /
`Int64.TryParse` are no longer routed through the kernel (pure-Lyric
int parsing in `Std.Parse` replaced them).

**Gap**: Parsing involves character-level iteration over the input
string, which is outside the decidable fragment.  The result-range
postconditions (`result.value >= Int.min` etc.) are trivially true by
type but must be axiomatised so the prover can use them downstream.

**Caller obligation**: None.  The parsing functions are total; they
return `Option[T]` (or equivalent) without throwing.

**Review**: Stable.

---

## 5. Text and encoding

### `Std.FormatHost` — `lyric-stdlib/std/_kernel/format_host.l`

```
@axiom("System.Globalization.CultureInfo and System.String/Int/Double formatting operations conform to their documented .NET contracts")
```

**BCL surface**: `String.Format` and the numeric `ToString` overloads
that accept a format specifier and a `CultureInfo`, backing the `format`
family in `Std.Core`.

**Gap**: Culture-sensitive formatting depends on locale data that
changes at runtime; the prover has no model of culture or locale.
The output type (`String`) carries no structural postcondition.

**Caller obligation**: The format string must be a compile-time
constant if the caller is in `@proof_required` code — dynamic format
strings are an unchecked invariant in the kernel (V0009 / unsafe block
required).

**Review**: Stable.

### `Std.EncodingHost` — `lyric-stdlib/std/_kernel/encoding_host.l`

```
@axiom("placeholder — no host calls remain in this boundary file")
```

**BCL surface**: empty.  Pure-Lyric encoding helpers replaced every
host call (UTF-8 / base64 / hex are now native Lyric on top of byte
slices).  The axiom is retained as a placeholder so the file is
discoverable by the audit lint; remove it when the file is deleted.

**Gap**: Base-64 and UTF-8 encode/decode involve byte-level iteration
and produce `slice[Byte]` / `String` values whose contents cannot be
characterised in first-order terms without a full string model.

**Caller obligation**: `FromBase64String` input must be a valid
Base64 string (BCL throws `FormatException` otherwise); the kernel
does not validate this.  In `@proof_required` code, callers must
establish input validity.

**Review**: Stable.

### `Std.CharHost` — `lyric-stdlib/std/_kernel/char_host.l`

```
@axiom("System.Char and System.Convert character operations conform to their documented .NET contracts")
```

**BCL surface**: `System.Char` (IsLetter, IsDigit, IsWhiteSpace,
IsUpper, IsLower, ToUpper, ToLower, IsHighSurrogate, IsLowSurrogate)
and `System.Convert` (ToChar), backing `Std.Char`.

**Gap**: Unicode character properties depend on Unicode table data
that is version-specific and cannot be captured in first-order contracts.

**Caller obligation**: None.  All predicates and conversions are total
on the `Char` (UTF-16 code unit) domain.

**Review**: Stable.

### `Std.UnicodeHost` — `lyric-stdlib/std/_kernel/unicode_host.l`

```
@axiom("System.Char.GetUnicodeCategory returns System.Globalization.UnicodeCategory whose underlying type is int32")
```

**BCL surface**: `System.Char.GetUnicodeCategory`, used by the
self-hosted lexer's UAX #31 XID_Start / XID_Continue classifier.

**Gap**: The BCL returns an `enum` value; Lyric sees it as an `Int`
via the underlying type.  The enumeration member values (0–29) are
part of the .NET public API but cannot be proved in Lyric without
enumerating all of Unicode.

**Caller obligation**: The caller must treat the `Int` result as one
of the 30 known category values and not as an arbitrary integer.

**Review**: Stable.

---

## 6. Storage

### `Std.FileHost` — `lyric-stdlib/std/_kernel/file_host.l`

```
@axiom("System.IO.File / Directory operations conform to their documented .NET contracts")
```

**BCL surface**: `System.IO.File` (ReadAllText, WriteAllText,
ReadAllBytes, WriteAllBytes, Exists, Delete), `System.IO.Directory`
(Exists, CreateDirectory, GetFiles, GetDirectories, Delete),
`System.IO.Path` helpers.  Note: these are separate from `Std.IO`'s
declarations — `FileHost` handles the typed `Result`-returning
wrappers; `Std.IO`'s file functions are the raw thin shims used
internally.

**Gap**: Filesystem state is observable shared mutable state;
pre/postconditions depend on OS state that the prover does not model.

**Caller obligation**: Non-empty paths (enforced by the kernel's own
`requires:` clauses).  Callers that need existence guarantees must
probe with `fileExists` / `directoryExists` first; the prover cannot
track filesystem state changes across calls.

**Review**: Stable.

### `Std.PathHost` — `lyric-stdlib/std/_kernel/path_host.l`

```
@axiom("System.IO.Path operations conform to their documented .NET contracts")
```

**BCL surface**: `System.IO.Path` (Combine, GetExtension, GetFileName,
GetDirectoryName, IsPathRooted), backing `Std.Path`.

**Gap**: Path operations depend on host OS string conventions (Windows vs.
POSIX) that the prover does not model.  The operations are pure (no filesystem
access), but the output contains host-platform separators.

**Caller obligation**: None.  All functions are total on their string inputs.

**Review**: Stable.

---

## 7. Time

### `Std.TimeHost` — `lyric-stdlib/std/_kernel/time_host.l`

```
@axiom("System.DateTime / System.TimeSpan / System.DateTimeOffset / System.TimeZoneInfo conform to their documented .NET contracts")
```

**BCL surface**: `System.DateTime` (UtcNow, Add, AddMonths, etc.),
`System.TimeSpan` (arithmetic), `System.DateTimeOffset`
(FromUnixTimeMilliseconds, ToUnixTimeMilliseconds), `System.TimeZoneInfo`
(FindSystemTimeZoneById, ConvertTime), backing `Std.Time`.

**Gap**: Wall-clock time is an observable external input; `DateTime.UtcNow`
is non-deterministic from the prover's perspective.  Calendar arithmetic
(AddMonths, AddYears) involves month-length and leap-year rules that are
not captured in first-order arithmetic.

**Caller obligation**: `TimeZoneInfo.FindSystemTimeZoneById` may throw
if the IANA timezone database is missing on the host; in practice this
is a deployment concern, not a precondition that the prover can check.

**Review**: Stable.

---

## 8. Network

### `Std.HttpHost` — `lyric-stdlib/std/_kernel/http_host.l`

```
@axiom("System.Net.Http operations conform to their documented .NET contracts")
```

**BCL surface**: `System.Net.Http.HttpClient` (GetStringAsync,
PostAsync, etc.) and `System.Net.Http.HttpResponseMessage`, backing
`Std.Http`.

**Gap**: Network I/O is non-deterministic; responses depend on
external state.  Cancellation tokens, timeout policy, and redirect
policy involve async state machines that are outside first-order scope.

**Caller obligation**: URLs must be well-formed (BCL throws `UriFormatException`
otherwise).  In `@proof_required` code, URL construction must be
validated before the kernel call.

**Review**: Stable.

---

## 9. System and process

### `Std.EnvironmentHost` — `lyric-stdlib/std/_kernel/environment_host.l`

```
@axiom("System.Environment operations conform to their documented .NET contracts")
```

**BCL surface**: `System.Environment` (GetEnvironmentVariable,
GetEnvironmentVariables, CurrentDirectory, ProcessId, Exit), backing
`Std.Environment`.

**Gap**: Environment variables are observable external process state;
their values are non-deterministic at the point where the Lyric program
calls them.

**Caller obligation**: None for reads.  `Environment.Exit` terminates
the process; it is a non-returning call that the prover treats as
unreachable beyond the call site.

**Review**: Stable.

### `Std.ProcessHost` — `lyric-stdlib/std/_kernel/process_host.l`

```
@axiom("System.Diagnostics.Process conforms to its documented .NET contracts")
```

**BCL surface**: `System.Diagnostics.Process` (Start, WaitForExit,
ExitCode, Kill), backing `Std.Process`.

**Gap**: Child-process lifecycle (exit code, stdio redirection, signal
handling) is OS-observable state that the prover cannot model.  Spawn
failure (`Process.Start` returning `null` or throwing) is a runtime
error the prover cannot predict.

**Caller obligation**: `fileName` must be a non-empty, accessible
executable path.  The kernel has no `requires:` for existence; the
wrapper (`Std.Process`) converts OS-level failures to a `Result` type.

**Review**: Stable.

### `Std.ProcessCaptureHost` — `lyric-stdlib/std/_kernel/process_capture_host.l`

```
@axiom("System.Diagnostics.Process piped stdout capture")
```

**BCL surface**: `Lyric.Emitter.ProcessCapture.runCapture` — spawns a child
process, writes to its stdin, and returns its stdout text.  Used by
`Lyric.Verifier` to invoke z3/cvc5.

**Gap**: Child-process lifecycle (spawn, I/O redirection, exit) involves OS
state that cannot be modelled in first-order logic.  Spawn failure and I/O
errors are converted to empty-string returns at the kernel boundary.

**Caller obligation**: `executable` must be a valid path on the host system.
The verifier pre-checks this; application code should not use this module.

**Review**: Stable.

### `Std.VerifierEnvHost` — `lyric-stdlib/std/_kernel/verifier_env_host.l`

```
@axiom("System.Environment.GetEnvironmentVariable with null → empty-string safety")
```

**BCL surface**: `Lyric.Emitter.VerifierEnv.getEnv` (a shim that converts
`null` to `""`) and `System.OperatingSystem.IsWindows`.

**Gap**: Environment variables are observable non-deterministic process state.
`IsWindows` is a platform intrinsic; the prover does not model platform.

**Caller obligation**: Callers must not rely on the value of any specific
environment variable being present or stable.

**Review**: Stable.

---

## 10. Serialization

### `Std.JsonHost` — `lyric-stdlib/std/_kernel/json_host.l`

```
@axiom("System.Text.Json operations conform to their documented .NET contracts")
```

**BCL surface**: `System.Text.Json.JsonSerializer` (Serialize,
Deserialize) and related types, backing the `@generate(Json)` source-gen
in `Std.Json`.

**Gap**: JSON serialization involves reflection (for the BCL-side codegen
path) and string-based encoding that is outside first-order scope.
The `@generate(Json)` compile-time path generates type-specific code
and does not use runtime reflection; the axiom covers the kernel FFI
layer regardless.

**Caller obligation**: Input to `Deserialize` must be valid JSON; the
BCL throws `JsonException` on malformed input.  `Std.Json.fromJson`
wraps this in a `Result`; in `@proof_required` code, callers must
not assume the `Result.value` is a specific Lyric value without an
explicit postcondition.

**Review**: Stable.

---

## 11. Identity

### `Std.UuidHost` — `lyric-stdlib/std/_kernel/uuid_host.l`

```
@axiom("System.Guid conforms to its documented .NET contract")
```

**BCL surface**: `System.Guid` (NewGuid, Empty, ToString, Parse,
TryParse), backing `Std.Uuid`.

**Gap**: `Guid.NewGuid()` uniqueness is a probabilistic property;
the prover cannot reason about randomness.  The `!= empty`
postcondition is the weakest useful claim that can be axiomatised
without a randomness model.

**Caller obligation**: If the caller needs identity guarantees
(two calls produce distinct values), that cannot be established
through this axiom alone and must be handled architecturally (e.g.,
storing and comparing IDs in a repository with a unique constraint).

**Review**: Provisional.  The V4 UUID collision probability is
negligible in practice but not zero; a stronger model is tracked in
`docs/06-open-questions.md`.

---

## 12. Logging

### `Std.LogHost` — `lyric-stdlib/std/_kernel/log_host.l`

```
@axiom("Host logging writes diagnostic messages according to its configured sinks")
```

**BCL surface**: The host logging abstraction (Microsoft.Extensions.Logging
or equivalent) used by `Std.Log`.

**Gap**: Logging is I/O with observable side-effects (writes to sinks,
structured log records, rate limiting).  The configured sinks are a
runtime deployment concern that cannot be modelled in first-order logic.

**Caller obligation**: None.  Log calls are fire-and-forget; the
postcondition is `Unit`.  Structured log fields must not contain
`null` in the underlying BCL sense — the kernel converts `Option[String]`
to a safe representation before dispatch.

**Review**: Stable.

---

## 13. Randomness

### `Std.RandomHost` — `lyric-stdlib/std/_kernel/random_host.l`

```
@axiom("System.Random conforms to its documented .NET contracts; the Shared property returns a thread-safe shared instance (documented since .NET 6)")
```

**BCL surface**: `System.Random` (Shared, constructor, Next, NextInt64,
NextDouble), backing `Std.Random`.

**Gap**: PRNG output is modelled as non-deterministic from the prover's
perspective.  Thread-safety of the shared instance depends on documented BCL
behaviour that cannot be proved inside Lyric.

**Caller obligation**: Callers must not use `Std.Random` for security-sensitive
values (token generation, key material, nonces).  Use `Std.SecureRandom`
instead.

**Review**: Stable.

---

## 14. Cryptography

### `Std.SecureRandomHost` — `lyric-stdlib/std/_kernel/secure_random_host.l`

```
@axiom("System.Security.Cryptography.RandomNumberGenerator conforms to its documented .NET contracts and produces cryptographically strong output")
```

**BCL surface**: `System.Security.Cryptography.RandomNumberGenerator`
(GetInt32 overloads, GetBytes), backing `Std.SecureRandom`.

**Gap**: CSPRNG output is by design non-deterministic and depends on OS entropy
state.  Cryptographic strength is a probabilistic claim that the prover cannot
discharge.

**Caller obligation**: None.  All static methods are total and return fresh
values from the OS CSPRNG on every call.

**Review**: Stable.

---

## 15. JVM stdlib kernel boundary

These entries are in `lyric-stdlib/std/_kernel/` and are JVM-target only.
They count toward the shared extern cap (D038 Decision F) because they live
in the same `_kernel/` directory as the .NET entries.

### `Std.Jvm` — `lyric-stdlib/std/_kernel/jvm.l`

```
@axiom("Std.Jvm provides JVM-target escape hatches for interoperating with
        Java exception semantics per docs/31-maven-linking.md Q-J012")
```

**BCL surface** (JVM): Java `try-catch` semantics via the JVM emitter's
`tryCatch` codegen hook.

**Gap**: Java checked-exception semantics are not part of the Lyric type
system.  The JVM emitter inserts the `try-catch` at the bytecode level;
the prover cannot reason about it.

**Caller obligation**: Callers must handle both `Ok` and `Err` arms —
`Error` subclasses propagate as unrecoverable JVM errors and are not caught.

**Review**: Provisional (Phase 6).

### `Std.JvmExceptionHost` — `lyric-stdlib/std/_kernel/jvm_exception.l`

```
@axiom("java.lang.Exception is the Java checked-exception root;
        JvmException wraps it for Lyric callers at the FFI boundary
        per docs/31-maven-linking.md §5")
```

**BCL surface** (JVM): `java.lang.Exception` as the supertype for all checked
exceptions; `JvmException` is the Lyric opaque wrapper.

**Gap**: Java exception hierarchies are a runtime property; the prover cannot
model Java checked-exception resolution.

**Caller obligation**: Use `Std.Jvm.tryCatch` to catch `JvmException`; do not
use this module directly in application code.

**Review**: Provisional (Phase 6).

### `Std.<HostPackage>` — `lyric-stdlib/std/_kernel_jvm/*.l` (`@cfg(feature = "jvm")`)

The directory `lyric-stdlib/std/_kernel_jvm/` mirrors `_kernel/` for the
JVM target — each file selects a Java BCL extern surface that the
`@cfg(feature = "jvm")` predicate routes to when compiling
`--target jvm`.  21 files currently carry `@axiom(...)` annotations
covering operations on `java.lang.String`, `java.util.{ArrayList,
HashMap}`, `java.io.{File,FileInputStream,FileOutputStream,Files}`,
`java.lang.{Math,Character}`, `java.net.URI`, `java.util.regex.Pattern`,
`java.nio.charset.StandardCharsets`, `java.security.MessageDigest`,
`java.time.{Instant,Duration,LocalDateTime}`, `java.util.UUID`, and
`java.lang.System` (env, out, err).

**Coverage**: per-file audit text is pending (`#335` follow-up).  The
counts below are tracked in section 18 alongside the .NET totals.

**Review**: Provisional pending per-file write-up.

---

## 16. `lyric-otel` library kernel boundary

These axioms appear in the `lyric-otel` library's kernel files and
follow the same extern-boundary pattern as `lyric-stdlib/std/_kernel/`.
They assert that the named CLR / JVM namespaces are present in the
runtime and expose the functions declared in the `extern package` block.
All are provisional pending weaver integration.

### 16.1. .NET kernel (`OTel.Kernel.Net`, `@cfg(feature = "dotnet")`)

| Claim | `@axiom` argument | Status |
|---|---|---|
| `System.Diagnostics.ActivitySource.StartActivity` is callable | `"System.Diagnostics"` | Provisional |
| `System.Diagnostics.Metrics.Meter` counter/histogram are callable | `"System.Diagnostics.Metrics"` | Provisional |

### 16.2. JVM kernel (`OTel.Kernel.Jvm`, `@cfg(feature = "jvm")`, Phase 6)

| Claim | `@axiom` argument | Status |
|---|---|---|
| `io.opentelemetry.api.trace.Tracer` is accessible | `"io.opentelemetry.api.trace"` | Provisional (Phase 6) |
| `io.opentelemetry.api.metrics.Meter` is accessible | `"io.opentelemetry.api.metrics"` | Provisional (Phase 6) |

---

## 17. How to add a new axiom

1. Identify the appropriate `lyric-stdlib/std/_kernel/<module>.l` file.  If no
   existing file covers the BCL surface, create a new one following the
   kernel file template (package-level `@axiom`, single-concern extern
   boundary, `Internal: only Std.<X> should import this` comment).
2. Add the `@externTarget` function(s) with any checkable `requires:` /
   `ensures:` clauses the BCL specification supports.
3. Annotate the **package** with `@axiom("<claim>")` if the file is new,
   or extend the existing axiom's claim string if the gap is the same.
4. Add an entry to this document in the appropriate section, following the
   template in §1.
5. Submit the entry for review.  The decision log entry
   (`docs/03-decision-log.md`) records the reviewer's sign-off.
6. The `lyric public-api-diff` tool includes `@axiom` declarations
   in its diff output; removing or weakening an axiom's `ensures:`
   is a semver-breaking change.

---

## 18. Axiom count by kernel package

### .NET kernel (`lyric-stdlib/std/_kernel/`)

| Kernel package           | File                         | Stable | Provisional |
|--------------------------|------------------------------|--------|-------------|
| `Std.IO`                 | `io.l`                       | 1      | 0           |
| `Std.ConsoleHost`        | `console_host.l`             | 1      | 0           |
| `Std.CollectionsHost`    | `collections_host.l`         | 1      | 0           |
| `Std.MathHost`           | `math_host.l`                | 1      | 0           |
| `Std.ParseHost`          | `parse_host.l`               | 1      | 0           |
| `Std.FormatHost`         | `format_host.l`              | 1      | 0           |
| `Std.EncodingHost`       | `encoding_host.l`            | 1      | 0           |
| `Std.CharHost`           | `char_host.l`                | 1      | 0           |
| `Std.UnicodeHost`        | `unicode_host.l`             | 1      | 0           |
| `Std.FileHost`           | `file_host.l`                | 1      | 0           |
| `Std.PathHost`           | `path_host.l`                | 1      | 0           |
| `Std.TimeHost`           | `time_host.l`                | 1      | 0           |
| `Std.HttpHost`           | `http_host.l`                | 1      | 0           |
| `Std.EnvironmentHost`    | `environment_host.l`         | 1      | 0           |
| `Std.ProcessHost`        | `process_host.l`             | 1      | 0           |
| `Std.ProcessCaptureHost` | `process_capture_host.l`     | 1      | 0           |
| `Std.VerifierEnvHost`    | `verifier_env_host.l`        | 1      | 0           |
| `Std.JsonHost`           | `json_host.l`                | 1      | 0           |
| `Std.UuidHost`           | `uuid_host.l`                | 1      | 0           |
| `Std.LogHost`            | `log_host.l`                 | 1      | 0           |
| `Std.RandomHost`         | `random_host.l`              | 1      | 0           |
| `Std.SecureRandomHost`   | `secure_random_host.l`       | 1      | 0           |
| `Std.HashHost`           | `hash_host.l`                | 1      | 0           |
| `Std.Regex`              | `regex.l`                    | 1      | 0           |
| `Std.Testing.Mocking`    | `testing_mocking.l`          | 1      | 0           |
| `Std.Jvm`                | `jvm.l`                      | 0      | 1           |
| `Std.JvmExceptionHost`   | `jvm_exception.l`            | 0      | 1           |
| **Total**                |                              | **25** | **2**       |

### JVM kernel (`lyric-stdlib/std/_kernel_jvm/`)

Per-file write-ups are pending (`#335` follow-up); the counts below
match the `@axiom("...")` annotations actually present in
`lyric-stdlib/std/_kernel_jvm/*.l` and are kept in sync with the
audit-lint script (`scripts/audit-axioms.sh`).

| Kernel package           | File                         | Stable | Provisional |
|--------------------------|------------------------------|--------|-------------|
| `Std.IO` (JVM)           | `io.l`                       | 1      | 0           |
| `Std.CharHost`           | `char_host.l`                | 1      | 0           |
| `Std.CollectionsHost`    | `collections_host.l`         | 1      | 0           |
| `Std.ConsoleHost`        | `console_host.l`             | 1      | 0           |
| `Std.EncodingHost`       | `encoding_host.l`            | 1      | 0           |
| `Std.EnvironmentHost`    | `environment_host.l`         | 1      | 0           |
| `Std.FileHost`           | `file_host.l`                | 1      | 0           |
| `Std.FormatHost`         | `format_host.l`              | 1      | 0           |
| `Std.HttpHost`           | `http_host.l`                | 1      | 0           |
| `Std.JsonHost`           | `json_host.l`                | 1      | 0           |
| `Std.LogHost`            | `log_host.l`                 | 1      | 0           |
| `Std.MathHost`           | `math_host.l`                | 1      | 0           |
| `Std.ParseHost`          | `parse_host.l`               | 1      | 0           |
| `Std.PathHost`           | `path_host.l`                | 1      | 0           |
| `Std.ProcessHost`        | `process_host.l`             | 1      | 0           |
| `Std.ProcessCaptureHost` | `process_capture_host.l`     | 1      | 0           |
| `Std.RandomHost`         | `random_host.l`              | 1      | 0           |
| `Std.SecureRandomHost`   | `secure_random_host.l`       | 1      | 0           |
| `Std.TimeHost`           | `time_host.l`                | 1      | 0           |
| `Std.UnicodeHost`        | `unicode_host.l`             | 1      | 0           |
| `Std.UuidHost`           | `uuid_host.l`                | 1      | 0           |
| **Total**                |                              | **21** | **0**       |

### Combined total

25 + 21 = **46** stable + **2** provisional = **48** `@axiom`
annotations covering the entire extern boundary across both
targets.

Note: the old `std.bcl.*` entries from the M4.3 baseline (11 axioms in 6
modules) were the conceptual design-doc predecessors of the current
kernel axioms.  The kernel refactor (D-progress-140 and surrounding
entries) moved every BCL extern to `lyric-stdlib/std/_kernel/`, replacing
per-function `@axiom` annotations with package-level annotations that
cover the entire extern boundary of each kernel file.  The axiom count
grew from 11 (M4.3 baseline) → 16 (after D-progress-140) → 22 + 2 JVM
→ 25 + 21 + 2 (current) as additional BCL surfaces were added (Console,
Path, ProcessCapture, VerifierEnv, Random, SecureRandom, Hash, Regex,
Testing.Mocking) and the JVM target boundary was brought under the
same audit framework.
