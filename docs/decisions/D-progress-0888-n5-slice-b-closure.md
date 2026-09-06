# D-progress-888 — Native N5 slice B closure: residual-seam audit finds the tracker's own four named deferrals already resolved elsewhere, ships three more small seams, files three new precisely-scoped compiler gaps (issue #4752)

**Status:** shipped

**Context.** #4752 ("N5 slice B") is a tracking issue for exception-free
kernel-`Result` seams across `Std.File`/`Std.Environment`/`Std.Process`/
`Std.Time`'s native twins, itself mostly shipped (D-progress-557,
D-N-023/024/025). Its own "Known deferrals" section named four specific
remaining gaps. This entry is the audit the issue asked for: verify each
deferral against the CURRENT tree (not the issue's original, now-stale
text), diff every dotnet `_kernel/*.l` public function against its native
`_kernel_native/*.l` twin for the four modules, and either close a gap or
document precisely why it stays open.

**All four of the issue's own originally-named deferrals are already
resolved, by separate, earlier work — verified directly, not assumed:**

1. **runCapture timeout/stdin** — the issue said the native seam "ignores
   `timeoutMs` and rejects non-empty stdin"; `lyric_process_run`
   (`lyric_process.c`) now takes both, confirmed reading the current
   function signature and by `llvm_stdlib_self_test.l`'s existing
   `Std.Process capture` case (stdin round-trip, sync timeout). Shipped in
   D-N-024, D-progress-557 addendum — the tracker's own text simply
   predates that PR.
2. **`Std.Uuid`** ("`Uuid` is an extern BCL value type... needs an
   Option-returning seam") — `llvm_stdlib_self_test.l`'s existing `Std.Uuid
   seams` case (v4 generation, formatting, four parse forms) already
   passes; `Std.Uuid` has its own native kernel today.
3. **`Std.Time` calendar surface** ("only the epoch/monotonic/sleep subset
   ships") — `time_host.l`'s dotnet-vs-native function-name diff (this
   entry's own audit) shows only ONE name absent on native
   (`hostDtoUtcNow`), confirmed unused anywhere in the shared `std/time.l`
   pure layer (dead code on the shared side, nothing to port); every
   calendar function (`hostAddDays`/`hostAddMonths`/`hostAddYears`/ISO
   parse/format/etc.) is present and covered by nine passing calendar
   cases in `llvm_stdlib_self_test.l` already, including five panic
   regressions (#5213/#5216/#5217/#5218/#5221/#5231/#5235).
4. **`out`-mode parameter lowering** — shipped as N9.6 (D-progress-853,
   issue #6794), unblocking `_kernel_native/http_server.l`'s
   `readOneRequest`.

**Function-level diff, dotnet `_kernel/` vs. native `_kernel_native/`, for
the four named modules** (`grep -oE 'pub func ...' | sort -u` on each
pair, by hand-verified reachability from the shared pure layer, not by
name alone):

- **`file_host.l`**: every dotnet function that is ALSO still called from
  the shared `std/file.l` pure layer has a native twin, except
  `hostReadAllBytes` (backs `readBytesOrPanic`) and the try/catch-blocked
  pair below. Every OTHER apparent gap (`hostReadAllText`/
  `hostWriteAllBytes`/`hostWriteAllText`/`hostCreateDirectory`/
  `hostDeleteDirectory`/`hostEnumerateFiles`/`hostEnumerateDirectories`/
  `hostEnumerateFileSystemEntries`/`hostDeleteFile`) is a pre-#4752-era
  name the pure layer no longer calls at all (superseded by the
  `*Result`-suffixed seams already shipped) — confirmed by grepping
  `std/file.l`/`std/directory.l` for each name, not assumed from the
  function list alone.
- **`environment_host.l`**: `hostGetEnvironmentVariable` is dead on the
  shared side (superseded by `hostGetVarOpt`, confirmed unused via grep);
  `hostAppBaseDirectory`/`hostRuntimeDirectory`/`hostRuntimeIdentifier`/
  `hostExit` were the four genuinely still-missing ones. Two now ship
  (below); two remain, precisely scoped (below).
- **`time_host.l`**: fully covered (see point 3 above).
- **`process_capture_host.l`**: `hostRunCapture`/`hostRunCaptureTimeout`
  (string-argument forms) are called only from `Std.ProcessCapture`
  (`std/process_capture.l`) — a DIFFERENT, older, self-hosted-compiler-
  internal module (used by the verifier to invoke z3/cvc5 and by the
  source-generator runtime to invoke generator DLLs), not `Std.Process`
  and not lyric-mcp's stdio transport. Native `--target native` builds
  are user-program builds, not builds of the compiler's own internal
  tooling, so this module is out of this audit's practical scope —
  documented, not silently skipped.

**Three small seams shipped as a result of this audit:**

1. **`hostReadAllBytes`** (`_kernel_native/file_host.l`) backs
   `Std.File.readBytesOrPanic`. Unlike `readTextOrPanic` (which wraps its
   host call in `try`/`catch Bug`), `readBytesOrPanic`'s pure-layer body
   has NO `try`/`catch` around `hostReadAllBytes` on any target — its
   "panic on failure" contract is just "let the host call's failure
   propagate uncaught" (on dotnet, an uncaught BCL exception; native has
   no exceptions to propagate, D-N-003), so the native implementation
   panics directly on failure instead, reusing the already-shipped
   `hostReadBytesResult` seam rather than a new extern call
   (`slice[Byte]`/`List[Byte]` share representation on this target,
   D-N-015, so `.toArray()` bridges the two).
2. **`hostRuntimeDirectory`** (`_kernel_native/environment_host.l`)
   returns `""` unconditionally. Not a shortcut: `Std.Environment
   .runtimeDirectory`'s OWN public doc comment already documents empty
   string as valid ("may return an empty string in native-AOT
   scenarios") — native is exactly that case.
3. **`hostRuntimeIdentifier`** similarly returns `""` unconditionally,
   matching the JVM twin's own already-documented "no .NET RID equivalent
   here" contract for the identical reason.

**Two gaps found, NOT fixed here — filed as their own issues:**

1. **`hostExit`** needs an `extern func` with a `Never` return type;
   `Lyric.LlvmCodegen`'s `externDeclOf`/`retTypeToN` rejects this
   outright (`this type form is not yet supported for --target native
   (Phase N1)`), confirmed by direct repro
   (`extern func rtExit(code: Int): Never = "exit"` panics at compile
   time). `Never` itself IS otherwise supported on native (`panic`/
   `return`-diverging value contexts already lower to `NVoid`) — the gap
   is specifically the `extern func` declaration path. Filed as issue
   #6901 with a suggested fix (map a `Never`-typed extern return to LLVM
   `void`).
2. **`hostAppBaseDirectory`** (directory of the running executable, e.g.
   via `readlink("/proc/self/exe")` on Linux) is feasible but needs
   genuinely new `lyric-rt` C surface — deliberately deferred rather than
   bundled into this kernel-focused audit pass; `Std.Environment
   .appBaseDirectory`'s own `@stable(since = "0.1")` marks it the oldest,
   least-used probe of the four this module documents. Filed as issue
   #6937 and linked from the kernel's own module header (a review pass on
   this PR flagged the original "left as a disclosed comment, no issue"
   plan as an untracked gap once this PR closes #4752, the umbrella
   tracker it was otherwise riding on for discoverability) — no compiler
   change needed, a future PR can pick it up directly.

Also unchanged, and out of THIS entry's scope for the same reason as the
prior two gaps just above (`hostExit`/`hostAppBaseDirectory`): `Std.File.stat`/`fileStatIsNewer`
(needs an opaque timestamp twin AND hits `Std.File.stat`'s own
`try`/`catch` wrapper — the same D-N-003 `try/catch`-on-native rejection
#6887 tracks for `Std.Process`'s piped API, but #6887's scope and
suggested fix are specific to that facade's three functions, not
general, so the `Std.File` instances are filed separately as issue
#6961) and `Std.File.readTextOrPanic` (its own `try`/`catch` wrapper
hits the identical rejection, also #6961). Neither is fixable from a
kernel file alone.

**Verification.** `llvm_stdlib_self_test.l` gained two new cases
(`Std.File readBytesOrPanic`: round-trip plus a missing-path panic
regression using the file's own established
`assertTrue(exitCode != 42 and exitCode != 0, ...)` panic-detection
idiom; `Std.Environment runtimeDirectory/runtimeIdentifier`: both return
`""`), verified on real Linux CI (`--target native`, real `clang`) —
20/20 cases in that file pass, no regressions. `./bin/lyric fmt --write`
applied cleanly to every changed `.l` file.

**Related:** #4752 (this entry's issue — recommend closing, given every
originally-named deferral is resolved and the residual audit is now
complete and precisely documented), #6901 (new, `Never`-typed extern
funcs on native), #6937 (new, `hostAppBaseDirectory`'s tracking issue),
#6961 (new, the `Std.File.stat`/`readTextOrPanic` instances of the
D-N-003 `try/catch`-on-native gap #6887 tracks for `Std.Process`'s
piped API instead), the sibling `Std.ProcessPipedHost` audit (PR #6894,
same session — see D-progress-887, its own decision-log entry),
D-progress-557/D-N-023/024/025 (the earlier work this entry confirms
already closed three of the four original deferrals).
