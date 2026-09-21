# D-progress-940 — unknown `String` method call now caught at type-check time (T0113), plus `isNormalized`/`normalize` MSIL↔JVM parity (#7099)

**Status:** shipped

**Context.** `maybeUnknownMemberDiag` (`lyric-compiler/lyric/type_checker/typechecker_exprs.l`)
already emitted T0113 ("no method/member") for an unknown member on a
`TyUser` receiver, but its `match recv { ... }` had no arm at all for
`TyPrim(PtString)` — `String` is a primitive type (`TyPrim`), not `TyUser`,
so a call to a nonexistent `String` method (a typo, or a BCL method the
language never implemented, e.g. `"x".toLowerInvariant()`) type-checked
clean. The MSIL/JVM backends' `String`-method codegen (`lowerMethodCallMsil`
in `lyric-compiler/msil/codegen.l`, the mirrored table in
`lyric-compiler/jvm/codegen/04_calls.l`) both had a final "unrecognised
method" fallback that either panicked at build time (MSIL, added ahead of
this fix in commit `f2718787`) or degraded to a runtime-throw stub — either
way, the failure surfaced far later and at the wrong layer than the issue
asked for: "a compile-time diagnostic at the call site... ideally the
message lists the nearest matching built-in."

**Fix — the T0113 diagnostic.** Added a `TyPrim(PtString)` arm to
`maybeUnknownMemberDiag` mirroring the `TyUser` arm's leniency structure://
it returns (no diagnostic) for a universal method name (`toString`/`equals`/…),
a `builtinMember` field-style accessor (`length`/`isEmpty`), a name in the
new `isBackendIntrinsicStringMethodName` allowlist, or a name otherwise
present in `sigs` (an ordinary UFCS-callable function reachable by bare
name — covers a user's own same-named helper). Anything else emits
`T0113 no method '<name>' on type 'String'` at the call's span.

**Why the allowlist, not just `sigs.containsKey`.** The MSIL/JVM backends'
`String` intrinsics (`contains`, `substring`, `replace`, `isNormalized`,
`normalize`, `trim`, `trimStart`, `trimEnd`, `indexOf`, `lastIndexOf`,
`startsWith`, `endsWith`, `split`, `toLower`, `toUpper`) are resolved
unconditionally by both backends' hardcoded `memberName ==` dispatch,
independent of whether the file imports `Std.String` or any same-named
`sigs` entry is visible. A first cut that checked only `sigs.containsKey(name)`
false-positived T0113 on the pre-existing test "known String methods still
compile and run correctly" (`msil_project_bridge_self_test.l`), whose
source calls `.trim()`/`.toLower()`/`.contains()` with **no** `import
Std.String` at all — exactly the shape the backends are meant to support
without an import. `isBackendIntrinsicStringMethodName` is the explicit,
backend-authoritative name list (kept in sync with both codegen tables by
comment cross-reference) checked ahead of the `sigs` fallback, so intrinsic
calls stay clean regardless of import state, while a genuinely-unknown name
still fires.

**Self-discovered regression: `isNormalized`/`normalize` had zero JVM
support.** Adding the allowlist surfaced that `isNormalized`/`normalize`
were MSIL-only: `lyric-stdlib/std/string.l` had no `pub func isNormalized`/
`normalize` wrapper at all (confirmed via `grep -n "^pub func "`), and
`lyric-compiler/jvm/codegen/04_calls.l` had no intrinsic for either name.
`lyric-compiler/lyric/lexer.l:1235` (`val text = if buf.isNormalized() {
buf } else { buf.normalize() }`) is a real, pre-existing compiler-internal
caller that the new T0113 check would have broken on `--target jvm` had
this gone unnoticed. Fixed both gaps:

- `lyric-stdlib/std/string.l`: added `pub func isNormalized(s): Bool` /
  `pub func normalize(s): String` thin UFCS wrappers (mirroring every
  neighboring `String` method) around the same-named dot-intrinsic.
- `lyric-compiler/jvm/codegen/04_calls.l`: added the JVM intrinsic. Java has
  no `String`-instance-method equivalent — Unicode normalization lives on
  `java.text.Normalizer` as **static** methods taking a `CharSequence` plus
  a `Normalizer.Form` enum constant, so the new block emits
  `LGetstatic(Normalizer$Form.NFC)` + `LInvokestatic(Normalizer.isNormalized
  / .normalize)` instead of the usual `LInvokevirtual` pattern the other
  0-arg `String` intrinsics use.

Verified end-to-end on both targets (build **and** run, not just compile):
MSIL and JVM both print `true` / `hello` for an already-NFC `"hello"` input.

**Test updates.** Two pre-existing `msil_project_bridge_self_test.l` tests
predated this fix and needed updating to match the new (earlier, better)
failure layer:

- *"unknown method call on a String receiver panics at build time, not
  silently"* — used to assert a thrown `Bug` from `compileProjectToMsil`
  (the codegen-level panic from `f2718787`). The type-checker now catches
  it first via an ordinary diagnostic gate (`Lyric.DiagnosticUtil.diagReportAndAbort`
  prints to stderr and returns `Bool`; `pipeCheckAndMono` returning `None`
  makes `compileProjectToMsil` return `false`, no exception). Rewritten to
  assert on the `Bool` return value instead, matching the established
  `compileProjectToMsil` failure idiom (`llvm_project_self_test.l`'s
  `assertFalse(ok, ...)`). Renamed to *"... fails the build, not silently"*
  since it's no longer specifically a panic. Message-content coverage
  (the diagnostic's exact text) moved to a new `typechecker_self_test.l`
  test, which can inspect `CheckResult.diagnostics` directly — the bridge
  test's own `outDiagnostics` parameter is scoped to codegen-level
  F0021–F0025/F0034 conformance diagnostics, not general type-check output,
  so it can't carry this message.
- *"known String methods still compile and run correctly"* — was failing
  (false-positive T0113 from the `sigs.containsKey`-only first cut,
  described above); passes unchanged once the allowlist landed.

New `typechecker_self_test.l` tests: unknown `String` method emits T0113
with the method/receiver-type named in the message; every backend-intrinsic
`String` method (the full 15-name allowlist) stays clean even without
`import Std.String`.

**Verification.** `typechecker_self_test.l`: 432/432 (was 430/430; 2 new
cases). `msil_project_bridge_self_test.l`: 65/65 (2 tests updated, both
green). `jvm_cross_package_collision_self_test.l`: 10/10, no regressions.
Full `make lyric` end-to-end repro on both targets (JVM `isNormalized`/
`normalize` verified by actually running the built JAR).

**Related:** #7099 (this fix). No prior decision-log entry covered the
`f2718787` MSIL-only codegen panic this supersedes as the primary failure
layer.
