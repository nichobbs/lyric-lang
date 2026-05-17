# Lyric Standard Library Review

Scope: `stdlib/std/*.l`, `stdlib/std/_kernel/*.l`, `stdlib/std/_kernel_jvm/*.l`,
`stdlib/tests/*.l`, plus `docs/10-stdlib-plan.md`, `docs/17-axiom-audit.md`.

Verdict: **REQUEST CHANGES.** No CRITICAL security holes, but several HIGH-severity
correctness bugs and cross-platform parity gaps will fail at link / runtime on
the JVM target; the docs that supposedly authoritatively gate the kernel
trust boundary are stale enough to mislead reviewers.

---

## 1. Test coverage gap inventory

Public stdlib modules (35) versus test modules (16). The following stdlib
packages have **NO** tests anywhere under `stdlib/tests/`:

| Module                        | Severity | Notes                                                 |
|-------------------------------|----------|-------------------------------------------------------|
| `Std.Http` (`http.l`)         | HIGH     | Network-touching, async, retry/redirect/cancel logic. |
| `Std.Rest` (`rest.l`)         | HIGH     | Auth strategies, URL composition, JSON extraction.    |
| `Std.Json` (`json.l`)         | HIGH     | Bootstrap-grade leaf extractors, no JsonDoc dispose.  |
| `Std.Time` (`time.l`)         | HIGH     | Calendar arithmetic, epoch round-trip, ISO 8601.     |
| `Std.File` (`file.l`)         | HIGH     | Read/write paths, byte round-trip, TOCTOU.            |
| `Std.Directory` (`directory.l`)| HIGH    | enumerate*, delete, deleteRecursive (destructive).    |
| `Std.Process` (`process.l`)   | HIGH     | Argument quoting, spawn / wait / exit code.           |
| `Std.ProcessCapture`          | HIGH     | Used by self-hosted verifier to invoke z3/cvc5.       |
| `Std.Path` (`path.l`)         | MEDIUM   | Cross-platform string semantics differ JVM vs .NET.   |
| `Std.Log` (`log.l`)           | MEDIUM   | Structured-field formatting, log injection.           |
| `Std.Console` (`console.l`)   | MEDIUM   | EOF handling, error stream routing.                   |
| `Std.Stream` (`stream.l`)     | MEDIUM   | -                                                     |
| `Std.Environment`             | MEDIUM   | -                                                     |
| `Std.Collections`             | MEDIUM   | List/Map/Set wrappers — tested indirectly via others. |
| `Std.App`                     | LOW      | Probably minimal.                                     |
| `Std.Core` (proof variant)    | LOW      | `core_proof.l` — pure proofs, lightly exercised.      |
| `Std.Testing.Property`        | LOW      | Self-test only.                                       |
| `Std.Testing.Snapshot`        | LOW      | Self-test only.                                       |

The HIGH-rated absentees together cover every I/O surface in the stdlib
plus the only JSON / time / network entry points. Stdlib tests are the only
machine-checked spec for these modules — without them, the `@stable(since="1.0")`
labels are aspirational.

---

## 2. Cross-platform parity defects

### [HIGH] `Std.Json` will not link on the JVM target — missing kernel entries

`stdlib/std/json.l:172` (`tryGetDouble`), `:102` (`enumerateArray`), `:121`
(`enumerateObject`), and `:94` (`valueKind`) all call `hostTryGetDouble`,
`hostEnumerateArray`, `hostEnumerateObject`, and `hostValueKind` respectively.
The .NET kernel `stdlib/std/_kernel/json_host.l:78,95-122,84` declares all of
these, but `stdlib/std/_kernel_jvm/json_host.l` declares **none of them**
(file ends at line 79 after `hostEncodeString`). On the JVM target the
`Std.Json` public API will fail at link-resolution.  Additionally the five
`lyricJsonGet*Slice` helpers at `_kernel/json_host.l:157-284` (used by
`@derive(Json)`) have no JVM mirror at all.

**Fix**: mirror the array/object enumerators (`JsonArrayEnumerator`,
`JsonObjectEnumerator`, `JsonProperty`), `hostTryGetDouble`, `hostValueKind`,
and the five slice-readers in `_kernel_jvm/json_host.l`. Until then mark
`Std.Json` as `@cfg(feature = "dotnet")`.

### [HIGH] `Std.Console` cannot resolve on JVM

`stdlib/std/console.l:12` imports `Std.ConsoleHost`. The only kernel file
declaring `Std.ConsoleHost` is `stdlib/std/_kernel/console_host.l`. There is
**no** `_kernel_jvm/console_host.l`. The JVM kernel exposes equivalent shims
as `lyric.stdlib.jvm.ConsoleHost.{write,writeLine,errorWriteLine,readLine}` via
`Std.IO` in `_kernel_jvm/io.l:12-22`, but `Std.Console` does not import that.
Result: `Std.Console.print`/`println`/`error`/`readLine` are unresolved on JVM.

**Fix**: create `_kernel_jvm/console_host.l` with the same `Std.ConsoleHost`
package and host signatures, routed through `lyric.stdlib.jvm.ConsoleHost`.

### [HIGH] `Std.Path` cannot resolve on JVM

Same shape as Console: `stdlib/std/path.l:10` imports `Std.PathHost`; only
`_kernel/path_host.l` defines it. JVM kernel offers the equivalents as
`lyric.stdlib.jvm.FileHost.{combine,getExtension,getFileName,getDirectoryName,isPathRooted}`
inside `Std.IO` in `_kernel_jvm/io.l:73-78`, but `Std.Path` does not import that
package. `Std.Path.{join,extension,basename,dirname,isAbsolute,isRelative}`
will not link on JVM.

**Fix**: create `_kernel_jvm/path_host.l` mirroring `Std.PathHost`.

### [HIGH] `Std.ProcessCapture` is .NET-only

`stdlib/std/process_capture.l` is what the self-hosted verifier
(`compiler/lyric/lyric/verifier/`) uses to call out to z3/cvc5. There is no
`_kernel_jvm/process_capture_host.l`. So `lyric prove --target jvm` (or any
JVM build that imports `Std.ProcessCapture`) cannot link.

**Fix**: provide a JVM mirror that calls `ProcessBuilder` + I/O capture.

### [MEDIUM] JVM-only kernel files live in `_kernel/`, not `_kernel_jvm/`

`stdlib/std/_kernel/jvm.l` (Std.Jvm) and `stdlib/std/_kernel/jvm_exception.l`
(Std.JvmExceptionHost) both carry header comments "JVM-target only. The
.NET-target build never loads this file." They were placed in `_kernel/`
presumably because target-gating happens elsewhere, but the directory layout
is now misleading — a reader auditing `_kernel/` for the .NET trust boundary
sees JVM-only declarations interleaved with .NET ones.

**Fix**: move both files into `_kernel_jvm/`, or add a `// TARGET: jvm`
banner enforced by lint. The README in `_kernel/` should call out the
exception explicitly until the move lands.

### [MEDIUM] `.NET` parse via `Double.TryParse` is locale-dependent

`stdlib/std/_kernel/parse_host.l:11-12` binds `System.Double.TryParse` with
just `(string, out double)` — that overload uses `NumberStyles.Float |
AllowThousands` and `NumberFormatInfo.CurrentInfo` (current culture). In a
non-`en-US` locale `"3.14"` returns `false`. Meanwhile `Std.Format` formats
doubles with `CultureInfo.InvariantCulture` (`_kernel/format_host.l:27`), so
the same program can format a value it then refuses to parse.

**Fix**: bind the four-arg overload `Double.TryParse(string, NumberStyles,
IFormatProvider, out double)` with `Invariant` so parse and format agree.
JVM uses `Double.parseDouble` which is locale-independent — the asymmetry is
.NET-only.

---

## 3. Pure-Lyric parser correctness (Std.Xml, Std.Yaml, Std.Json)

### [HIGH] `Std.Yaml.yParseNumber` silently downgrades all floats to strings

`stdlib/std/yaml.l:393-397`:

```
if isFloat {
    // ...
    Ok(value = YString(value = raw))  // TODO: replace with real float parsing once toDouble lands
}
```

`parseJson("3.14")` succeeds and returns `YString("3.14")`, not `YFloat(3.14)`.
This silently breaks every caller that expects numeric semantics — and there is
no `asFloat`/`asDouble` accessor either, so consumers can't even tell the
parser misclassified. JSON parses `3.14` as a number per RFC 8259 §6.

**Fix**: route through `Std.Parse.parseOptDouble` (now that the pure-Lyric
integer parsers exist, the same pattern works) and emit `YFloat`. Add the
missing `asFloat`/`asDouble` accessor. Add tests for `3.14`, `1e10`, `-2.5e-3`.

### [HIGH] `Std.Yaml` lacks a recursion-depth limit (DoS)

`yParseValue` (`stdlib/std/yaml.l:527`) calls `yParseObject` / `yParseArray`
which call `yParseValue` again with no depth counter. A pathological
`{"a":{"a":{"a":...}}}` will recurse until the stack overflows. Same shape
applies to `yParseBlockNode` / `yParseBlockMapping` / `yParseBlockSequence`.
Std.Xml has the same problem via `xParseContent` ↔ `xParseElement`
(`stdlib/std/xml.l:466,545`). For a "safety-oriented application language"
this is the kind of DoS-vector that's expected to be caller-configurable.

**Fix**: thread a `depth: Int` counter through `yParseValue` / `xParseElement`,
default cap at e.g. 1024, return `UnsupportedFeature` / `InvalidDocument` when
exceeded. Add tests with > 1024 nesting levels.

### [HIGH] `Std.Yaml` "Norway problem" — YAML 1.1 truthy/falsy bool coercion

`stdlib/std/yaml.l:325-332` accepts `yes/Yes/YES/on/On/ON` as `YBool(true)` and
`no/No/NO/off/Off/OFF` as `YBool(false)`. This is YAML **1.1** behaviour. The
file header (line 1) advertises YAML **1.2** parsing — YAML 1.2 only recognises
`true/false` as booleans (`null/Null/NULL/~/""` for null). Parsing the country
`NO` as `false` is the canonical "Norway problem" data corruption bug.

**Fix**: drop `yes/no/on/off` from the boolean recognisers. If YAML 1.1 compat
is wanted, expose it as an explicit flag on `YamlState`.

### [HIGH] `Std.Yaml` accepts duplicate keys silently

`yParseObject` (`stdlib/std/yaml.l:447`) and `yParseBlockMapping`
(`stdlib/std/yaml.l:635`) push every `(key, value)` into `pairs` without a
membership check. The `DuplicateKey` union case (`stdlib/std/yaml.l:33`) and
the message text in `YamlError.message` (`:45-46`) are dead code — the parser
never produces them. Per YAML 1.2 §3.2.1.3 duplicate keys are an error.

**Fix**: maintain a `List[String]` of seen keys (or a `Set[String]` once
generic Set is stable), return `DuplicateKey` on collision. Tests should
cover `{a:1, a:2}` for both flow and block mappings.

### [HIGH] `Std.Yaml` anchor/alias guard only fires at document start

`yCheckUnsupported` (`stdlib/std/yaml.l:761`) is only called once from
`parseYaml` (`:800`) immediately after the leading blank/comment skip. An
anchor `&id` inside a nested value (e.g. `key: &id value`) is treated as part
of the scalar text. That means a "YAML 1.2 minus anchors" mode is not actually
enforced — content with anchors parses to a corrupted tree rather than
returning `UnsupportedFeature`.

**Fix**: in `yParseValue` and `yParseBlockNode`, reject leading `&` / `*` /
`!` / `<<` before any value, and inside attribute-style positions.

### [MEDIUM] `Std.Yaml` has dead/buggy `ySkipInlineWs` next to working version

`stdlib/std/yaml.l:118-132` defines `ySkipInlineWs` with a "sentinel overshoot"
hack:

```
if not (c == ' ' or c == '\t') {
  st.pos = st.src.length + 1  // break via sentinel — reset below
}
```

`ySkipSpaces` immediately after (`:154`) is the correct loop. `ySkipInlineWs`
is never called (`grep -n "ySkipInlineWs" stdlib/std/yaml.l` shows only the
definition). Dead code; delete it before someone copies the pattern.

### [MEDIUM] `Std.Xml` does not validate XML declaration version

`xParseXmlDecl` (`stdlib/std/xml.l:432-460`) accepts any pseudo-attribute and
discards them all — no enforcement that `version` is `1.0` / `1.1`, no
warning when `version` is missing. The struct field
`XmlDoc.version`/`encoding` is permanently `None` because
`parseXml` (`:619-633`) discards the parsed values and constructs
`XmlDoc(version = None, encoding = None, ...)`. Dead fields.

**Fix**: capture and surface version/encoding through `xParseXmlDecl`'s
return type, populate `XmlDoc.{version,encoding}` accordingly.

### [MEDIUM] `Std.Xml.xCollectText` swallows entity-parse errors

`xCollectText` (`stdlib/std/xml.l:271-279`) catches `xParseEntity` errors and
substitutes `?` rather than propagating the failure:

```
case Err(e) -> {
    scanning = false
    result = result + "?"
}
```

A malformed `&foo` in text becomes data corruption (`?`) rather than a parse
error.  The function signature is `Result[String, XmlError]` already; the
fix is to return `Err(e)`.

### [MEDIUM] `Std.Xml` accepts mismatched element names without rejecting prolog/epilog

`xCollectAll` walks any tree without checking namespace qualification (header
explicitly says no namespaces). For programs whose XML *does* have namespaces
this is fine, but `findAll(node, "h:title")` and `findAll(node, "title")` will
match different things depending on input style. Document this prominently in
the public API surface.

### [HIGH] `Std.Json` leaks `JsonDocument` (IDisposable) on every parse

`stdlib/std/_kernel/json_host.l:37` declares `hostParseJson` returning a
`System.Text.Json.JsonDocument` which is `IDisposable`. Nothing in
`stdlib/std/json.l` or the slice readers (`_kernel/json_host.l:157,183,208,233,261`)
ever disposes the document. Worse, the `lyricJsonGet*` family
(`stdlib/std/json.l:150-228`) re-parses the JSON for every field lookup — an
N-field object becomes an O(N²) parse plus N un-disposed documents. Real
applications will leak unmanaged memory at scale.

**Fix**: introduce a `disposeJson(doc: JsonDoc): Unit` extern bound to
`JsonDocument.Dispose`, wrap `lyricJsonGet*` in `defer { disposeJson(doc) }`
once defer-in-non-async lands, and at minimum parse once per request in
`Std.Rest.jsonString/jsonInt/jsonBool` rather than re-parsing per field.

---

## 4. Security and DoS

### [HIGH] `Std.Random` is not cryptographically secure but presented as the only RNG

`stdlib/std/_kernel/random.l` exposes `Std.Random` (note: NOT `Std.RandomHost`
— this kernel file IS the public surface) over `System.Random`, which is a
non-cryptographic linear-congruential / xoshiro PRNG. There is no
`Std.Crypto` / `Std.SecureRandom` package. `Std.Uuid.newUuid()` happens to
use `System.Guid.NewGuid()` which IS cryptographic on .NET — but a developer
who needs "secure random bytes for a session token" has no obvious
non-footgun primitive in the stdlib.

Also: the kernel breaks naming convention by publishing `Std.Random` directly
instead of routing through a `Std.Random` public file that imports
`Std.RandomHost`. The same is true of `Std.Regex` (next finding) and
`Std.Testing.Mocking` (`_kernel/testing_mocking.l:30`).

**Fix**: rename to `Std.RandomHost`, add a `stdlib/std/random.l` public
wrapper, and ship a `Std.SecureRandom` package wrapping
`System.Security.Cryptography.RandomNumberGenerator` (.NET) /
`java.security.SecureRandom` (JVM).

### [HIGH] `Std.Regex` allows catastrophic backtracking (ReDoS) by design

`stdlib/std/_kernel/regex.l:14-15` binds `Regex..ctor(string)` with no
`matchTimeout`. A pattern like `(a+)+$` against `aaaaaaaaaaaaaaaaa!` hangs
indefinitely.  Same for the JVM `Pattern.compile(String)` overload
(`_kernel_jvm/regex.l:30`).  For a safety-oriented language this is a
foot-gun.  No public `stdlib/std/regex.l` wrapper exists to add the timeout
either — the kernel file is the API.

**Fix**: bind the `Regex(string, RegexOptions, TimeSpan)` overload, default
the timeout to 1 s (overridable), and wrap calls so a TimeoutException maps
to `Result.Err`. Add a `stdlib/std/regex.l` public wrapper following the
`Std.Http` pattern. Document the ReDoS posture in
`docs/10-stdlib-plan.md`.

### [MEDIUM] `Std.Log` has no log-injection or escaping protection

`stdlib/std/log.l:50-55` formats fields as `key=value` with neither key nor
value escaped. A `value` containing `\n` writes a multi-line log entry
(easy log injection); a `value` containing `=` or a space ambiguates a later
log parser. The `msg` (`:64`) is passed through verbatim. CWE-117.

**Fix**: escape newlines, `=`, and `"` in both keys and values; consider
quoting values that contain whitespace. Document the escaping convention.

### [MEDIUM] `Std.Http.hostDefaultClient` instantiates a new `HttpClient` per call

`stdlib/std/_kernel/http_host.l:123-125`:

```
pub func hostDefaultClient(): HttpClient {
  newClient()
}
```

Every `getAsync` / `postAsync` / `sendAsync` (`stdlib/std/http.l:189,210,233`)
calls `hostDefaultClient()` afresh, which creates a new `HttpClient`. This is
the canonical .NET `HttpClient` anti-pattern: under load it exhausts the
TCP socket pool (`SocketException` after a few thousand requests) because
sockets stay in `TIME_WAIT` for two MSL after the client is GC'd. Microsoft
docs are explicit: `HttpClient` instances should be shared per host.

**Fix**: hold a process-static singleton (lazy-init) in a small kernel
helper. The JVM kernel already does the right thing
(`_kernel_jvm/http_host.l:32` — "defaultClient" routes through
`HttpClientHost.defaultClient` which is a process-wide singleton).

### [MEDIUM] `Std.Http` Bearer / Basic tokens are plain `String` — no zeroization

`stdlib/std/rest.l:60-61` carries the secret as a plain `String`. There is no
"secret" type or zeroization hook in `Std.Errors` / `Std.Core`; a token can end
up in process dumps, log files (`Std.Log` will happily write it), and
`Std.Time`-stamped traces.

**Fix**: introduce `Std.SecretString` opaque type with no `toString`, redact
in `Std.Log.formatFields`, and wrap `RestAuth.Bearer.token` in it. Track this
as a Phase-3 followup rather than a blocker.

---

## 5. Async, resource, and lifecycle

### [HIGH] `Std.Process.run` does not Dispose the spawned process handle

`stdlib/std/_kernel/process_host.l:27` returns
`System.Diagnostics.Process`, which is `IDisposable` (owns OS handles).
`Std.Process.run` (`stdlib/std/process.l:48-57`) and `runChecked` (`:64-69`)
extract `hostExitCode(proc)` and let `proc` drop — relying on GC + finalizer
to release the OS process handle. On a server-side workload that spawns
thousands of children this leaks handles for several GC cycles.

**Fix**: add `hostDisposeProc(p: ProcessHandle): Unit` extern, wrap the call
in `defer { hostDisposeProc(proc) }` (or its current equivalent).

### [HIGH] `Std.File.readBytes` re-implements a List from a slice in pure Lyric

`stdlib/std/file.l:117-121`:

```
val raw = hostReadAllBytes(path)
val acc: List[Byte] = newList()
for b in raw {
    acc.add(b)
}
Ok(value = acc)
```

For a 100 MB file this allocates the BCL `byte[]` (raw), then 100 M `acc.add`
calls each potentially re-allocating the backing `List<byte>` (doubling). This
is O(N) but with very high constant factor and memory peak. The slice already
*is* a `byte[]`; the public surface should be `slice[Byte]` (matching the
extern), and `List[Byte]` is unwarranted ceremony.

**Fix**: change the public return to `Result[slice[Byte], IOError]` and
similarly `writeBytes(path, bytes: in slice[Byte])`. If the existing
`List[Byte]` shape is locked in by the `@stable(since="1.0")` marker, at
minimum reserve capacity via a `newListWithCapacity(raw.length)` helper.

### [MEDIUM] `Std.File.readText` has a TOCTOU race between exists-check and read

`stdlib/std/file.l:51-58`:

```
if not hostFileExists(path) {
    return Err(error = FileNotFound(path = path))
}
return try {
    Ok(value = hostReadAllText(path))
}
```

If the file is deleted between line 51 and line 55 the user gets
`IoError("system error...")` instead of `FileNotFound`. Drop the probe;
classify the resulting host exception based on its type
(`FileNotFoundException`, `UnauthorizedAccessException`, etc.) instead.

### [LOW] `Std.Task.installToken` doc encourages defer pattern but doesn't enforce it

`stdlib/std/_kernel/task.l:286-292` returns the previous token so the caller
can `defer { restoreToken(previous) }`. A buggy caller that forgets the
defer leaks the installed token into the surrounding AsyncLocal flow. Worth
documenting a `withToken(token, action)` higher-order helper that takes care
of save/restore in one combinator.

---

## 6. Extern boundary discipline (CLAUDE.md invariant)

### [HIGH] `Std.Directory` imports `System.IO` directly instead of routing through `Std.FileHost`

`stdlib/std/directory.l:11`:

```
import System.IO as HostIO
```

This is the only public stdlib file that imports an `extern package` directly
(every other module imports `Std.<X>Host` from `_kernel/`). It works because
`_kernel/io.l:22` declares `extern package System.IO {...}`. But it bypasses
the convention that user-facing wrappers route through a `*Host` shim, and it
means `Std.Directory` is implicitly coupled to the JVM kernel's identical
`extern package System.IO` declaration (no separate JVM file exists, so this
*happens* to work but the layering is wrong).

**Fix**: have `Std.Directory` import `Std.FileHost` (or a new
`Std.DirectoryHost`) and have those host packages forward to `Std.IO`. The
goal stated in CLAUDE.md is "no `@externTarget` or `extern type` declarations
outside the kernel boundary" — `Std.IO` IS inside the kernel boundary, so the
invariant technically holds, but the API surface from user code should still
go through a *Host package consistently.

### [MEDIUM] Duplicate kernel boundaries for the same BCL surface

`_kernel/io.l` and `_kernel/file_host.l` both declare bindings for
`System.IO.File.{ReadAllText, WriteAllText, ...}` and
`System.IO.Directory.{Exists, CreateDirectory, ...}`. `_kernel/io.l` uses the
`extern package` syntax; `_kernel/file_host.l` uses `@externTarget`. They are
genuinely independent host packages (`Std.IO` and `Std.FileHost`) — both load
into the AppDomain. This doubles the trust-surface audit and is harder to
keep in sync (any new file op needs to be added to whichever happens to be
the routing path for the consumer).

**Fix**: consolidate to a single `Std.FileHost` declared with
`@externTarget`, and have `Std.IO` re-export selected functions, or remove
`Std.IO`'s file ops entirely. The §7 of `docs/14-native-stdlib-plan.md`
appears to call for the kernel to live in `_kernel/` — duplication is the
opposite intent.

### [MEDIUM] `Std.Regex` kernel file has no `@axiom` annotation

`stdlib/std/_kernel/regex.l` (line 7: `package Std.Regex`) lacks the
`@axiom("...")` package annotation that every other kernel file carries
(see e.g. `_kernel/file_host.l:14`). Same omission in
`_kernel/testing_mocking.l:30` (`package Std.Testing.Mocking`). The proof
system uses the package-level `@axiom` as the trust gate (per
`docs/17-axiom-audit.md` §1); unannotated kernel externs are an unguarded
trust boundary. The JVM `_kernel_jvm/regex.l:21` has the same gap.

**Fix**: add `@axiom("System.Text.RegularExpressions.Regex conforms to its
documented .NET contract (subject to ReDoS — caller-supplied patterns must
be bounded by the caller's policy)")` to all four files (and likewise for
mocking).

---

## 7. `docs/17-axiom-audit.md` is stale and out of sync with code

### [HIGH] Axiom audit lists 16 entries; code has 22 (.NET) + 16 (JVM)

The "Axiom count by kernel package" table at `docs/17-axiom-audit.md:482-502`
totals 16 stable + 0 provisional. Actual `@axiom` annotations in
`stdlib/std/_kernel/*.l` (counted via `grep -rn "@axiom" stdlib/std/_kernel/`)
total 22 (.NET) + 16 (JVM). The audit is missing entries for
`Std.PathHost`, `Std.ConsoleHost`, `Std.ProcessCaptureHost`,
`Std.JvmExceptionHost` / `Std.Jvm`, and `Std.VerifierEnvHost`. It also has no
entry for the `lyric.stdlib.jvm.*` axioms that live in `_kernel_jvm/`.

The Uuid axiom (`docs/17-axiom-audit.md:408`) is marked "Provisional" but
the code at `_kernel/uuid_host.l:16` carries it as a normal package
annotation — there is no machine-checkable distinction.

### [HIGH] Axiom audit text contradicts actual axiom strings

Two examples:

- `docs/17-axiom-audit.md:135` quotes `@axiom("System.Int32/Int64/Double/
  Boolean.TryParse conform to ...")` but `stdlib/std/_kernel/parse_host.l:8`
  actually says `@axiom("System.Double/Boolean.TryParse...")` — `Int32`/`Int64`
  were removed when pure-Lyric int parsing landed but the audit was not updated.
- `docs/17-axiom-audit.md:180` quotes `@axiom("System.Convert and
  System.Text.Encoding encoding operations conform to ...")` but
  `_kernel/encoding_host.l:11` says `@axiom("placeholder — no host calls
  remain in this boundary file")`. The migration to pure-Lyric encoding
  (D-progress-140 follow-up) was not reflected in the audit.

**Fix**: append a cleanup pass to `docs/17-axiom-audit.md` that re-scans
the kernel files and regenerates the count table + claim quotes. This is
exactly the kind of thing a CI lint can enforce (`scripts/audit-axioms.sh`
could read every kernel file's `@axiom("...")` and diff against the
audit document).

### [MEDIUM] Axiom audit has no JVM section beyond a stub

`docs/17-axiom-audit.md:438-459` (§13) is the only JVM-touching section, and
it covers only `lyric-otel`. The `stdlib/std/_kernel_jvm/*.l` files (16
package-level axioms over `lyric.stdlib.jvm.*` + JVM SDK targets) have no
entries. A reviewer auditing the JVM kernel today has no policy doc to check
against.

---

## 8. Smaller issues worth fixing in passing

### [MEDIUM] `HttpError.Timeout` is dead code

`stdlib/std/errors.l:92-94` declares `Timeout(url: String, durationMs: Long)`
but no code path produces it. `sendWithTimeoutAsync`
(`stdlib/std/http.l:382-401`) wraps cancellation into `ConnectionFailed`
with a message containing `"cancelled"`. Either wire timeouts up to
`HttpError.Timeout` (matching the public union's promise) or remove the
unused case.

### [MEDIUM] `Std.Encoding.encodeUtf8` produces WTF-8 for unpaired surrogates

`stdlib/std/encoding.l:184-189` encodes lone high surrogates as a 3-byte
sequence rather than rejecting them. This is WTF-8 (Web-style), not strict
UTF-8 per RFC 3629 §3 which forbids encoding D800-DFFF. The header at
`stdlib/std/encoding.l:14-15` says "rejects ... lone surrogates" — for the
*decoder* this is true, but the encoder is asymmetric. The discrepancy
matters when interoperating with strict-UTF-8 consumers (Rust, web
specifications).

**Fix**: either reject lone surrogates in `encodeUtf8` (return
`Result[slice[Byte], EncodingError]`) or document explicitly that the
encoder emits WTF-8 by design.

### [LOW] `Std.Time` exposes only UTC; no monotonic clock primitive

`Std.Time.now()` returns wall-clock UTC. There is no monotonic-clock helper
(`System.Diagnostics.Stopwatch` on .NET, `System.nanoTime` on JVM). For
duration measurements (the typical use case for "how long did this take")
wall-clock can go backwards on NTP corrections. This is exactly the kind of
distinction `docs/10-stdlib-plan.md` should call out as a planned
v1 deliverable.

### [LOW] `Std.Uuid` axiom is "Provisional" but provides no v7 / time-ordered alternative

UUID v4 is fine for randomness; for index-friendly time-sortable IDs (the
modern v6/v7 design) callers need a separate package. Track in
`docs/10-stdlib-plan.md` as a v1.x followup.

### [LOW] `Std.Set.setRemove` returns `Bool` — undocumented post-condition

`stdlib/std/set.l:36` documents "true if it was present, false if absent"
in prose but no `ensures:` clause. Same for `setAdd` (idempotence). For a
proof-aware stdlib these would be useful axioms.

### [LOW] `Std.Random` and `Std.Regex` violate `*Host` naming convention

Both kernel files declare a public-looking `Std.Random` / `Std.Regex`
package without the `Host` suffix used by every other kernel file. This
means user code imports them directly as if they were stable public APIs,
bypassing any future Lyric-side wrapper that wants to enforce additional
contracts (e.g. ReDoS timeouts on Regex, CSPRNG seeding on Random).

---

## 9. Positive observations

- The kernel boundary IS clean: a grep for `@externTarget`/`extern type`
  outside `stdlib/std/_kernel*/` returns zero hits. The discipline holds.
- `Std.Encoding` (Base64, Hex, UTF-8) is pure-Lyric and the decoders properly
  reject overlong sequences, lone surrogates in UTF-8 input, and invalid
  padding. Tests at `stdlib/tests/encoding_tests.l` cover the happy path.
- `Std.Parse.parseOptInt`/`parseOptLong` carefully accumulate as negative to
  cover `Int.MinValue` symmetric range — a subtle correctness win.
- `Std.Http`/`Std.Rest` consistently lift host failures into `Result` —
  no `Bug` escapes to application code.
- Self-hosted XML/YAML parsers eliminate a substantial extern dependency
  (cross-platform parity wins).
- The `protected type Scope` in `Std.Task` migrating off the F#
  `LyricTaskScope` shim is exactly the F#-surface-frozen direction CLAUDE.md
  prescribes.

---

## Severity summary

- CRITICAL: 0
- HIGH: 13
- MEDIUM: 11
- LOW: 5

## Recommendation

**REQUEST CHANGES.**

Highest priority (block any new release):

1. Fix the four JVM parity gaps (`Std.Json`, `Std.Console`, `Std.Path`,
   `Std.ProcessCapture`). Without these, "Lyric runs on JVM" is currently a
   per-program lottery depending on which stdlib packages the program imports.
2. Fix `Std.Yaml` float-as-string, Norway problem, duplicate-key swallowing,
   and add depth limits to both XML and YAML. The bootstrap-grade parsers are
   the *only* JSON/YAML/XML parsers shipped for JVM.
3. Re-sync `docs/17-axiom-audit.md` with the actual kernel files and add the
   missing entries.
4. Resolve `HttpClient` singleton anti-pattern and `Process` handle leak.

Medium priority (next sprint):

5. Add tests for Http, Rest, Json, Time, File, Directory, Process — the
   "untested HIGH" rows in §1.
6. Add a `Std.Crypto.SecureRandom` package and gate `Std.Regex` behind a
   timeout-bearing wrapper.
