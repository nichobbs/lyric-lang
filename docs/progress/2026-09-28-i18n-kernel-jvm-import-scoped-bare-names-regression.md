# lyric-i18n JVM `I18nKernelTests` failure was D141's bare-name import-scoping fix; add regression coverage (#7458)

`lyric test --target jvm --manifest lyric-i18n/lyric.toml` was reported
failing to build `tests/i18n_kernel_tests.l`:

```
error[T0060] 168:11: val binding declared as String but initialiser has type InProcessTranslationStore
```

while the same file passed on `--target dotnet`. Root cause: `I18n`
(`src/i18n.l`) and `I18n.Kernel` (`src/i18n_kernel.l`) are unrelated
sibling packages in the same manifest that both declare a
`pub func loadFromPath(path: in String): Result[_, _]`, with different
success types (`I18n.loadFromPath` returns
`Result[InProcessTranslationStore, I18nError]`;
`I18n.Kernel.loadFromPath` returns `Result[String, String]`).
`tests/i18n_kernel_tests.l` imports only `I18n.Kernel` and calls the bare
name `loadFromPath(path)`, matching `case Ok(text) -> { val textStr: String
= text }`.

Before D141 ("Enforce docs/01 §9.2 import scoping for bare names", #7535,
docs/decisions/D141-import-scoped-bare-names.md, merged the same day as
this investigation, ~09:57 UTC, shortly before this session started at
~08:58 UTC on an older `main`), a bare call with no import-rule filtering
picked the first-registered same-arity candidate whose parameter types
matched (`typechecker_exprs.l`'s old `primary = sigs[arityKey] or
sigs[name]`), with no check on whether the file actually imported the
candidate's declaring package. Both bridges bundle **every** project
package as a sibling registrant (`Jvm.Bridge`/`Msil.Bridge`
`compileProjectToJar*`/`compileProjectToMsil*`, #7583's "every package
sees the same registered set"), so `I18n` — never imported by the test
file — was still a visible same-name candidate; whichever of `I18n` /
`I18n.Kernel` registered first for the `loadFromPath` arity-key slot won
the bare call, independent of the file's own `import` list. D141 added
`symTableBareFuncTier`/`installImportRule` (`typechecker_symbols.l`,
`typechecker_checker.l`) so a bare call only considers candidates the
file's own (transitive whole-)imports make visible; `I18n` is correctly
excluded and `I18n.Kernel`'s `loadFromPath` is the only visible
candidate, matching `--target dotnet`'s (already-correct, by
construction, for a different reason unrelated to this regression) result.

Confirmed the failure no longer reproduces against current `main`
(`lyric test --target jvm --manifest lyric-i18n/lyric.toml`: 53/53 +
10/10 pass) — D141 landed on `main` shortly before this investigation and
already fixes it; D141's own PR touched `lyric-i18n/src/i18n.l`
separately (rewrote an unrelated `readText(path)` bare call the same
import-scoping tightening affected inside `loadFromPath`'s own body) but
did not add coverage for a same-named function belonging to a package the
consumer never imports at all (only "two direct imports" and "two
transitively-reached imports" collision shapes had self-tests).

Added `lyric-compiler/lyric/typechecker_self_test.l` test "a same-named
function declared only by a never-imported sibling package never wins
(#7458)": two `ImportedPackage`s (`PkgRecSibling`/`PkgStrDirect`) declare
`loadPath(path: in String)` with different `Result` success types; a
consumer imports only `PkgStrDirect` and matches the bare call's `Ok`
payload into a `String`-declared `val`. `PkgRecSibling` is registered
FIRST in the `List[ImportedPackage]` passed to
`checkWithImportedPackages` (the pre-D141 registration-order-dependent
failure mode), so this pins that the never-imported sibling's candidate
never wins regardless of registration order. Verified this test would
have failed pre-D141: reverting `typechecker_checker.l` /
`typechecker_exprs.l` / `typechecker_symbols.l` /
`typechecker_resolver.l` / `pipeline.l` to their pre-D141
(`331e5447`) state, an isolated copy of this test (built and run
standalone against those reverted files, sidestepping D141's
touches elsewhere in the compiler tree that the full self-test file
now also depends on) reproduces `diagCount(cr) == 0` failing —
`text` bound to `PkgRecSibling`'s `Store` type, exactly the original
`I18nKernelTests` symptom.

Added `lyric-i18n` to `scripts/ci/jvm-ecosystem-suites.sh` (the `libs`
array and the header's per-suite coverage comment) so the full
`lyric-i18n` suite (`i18n_tests.l` + `i18n_kernel_tests.l`, 63 cases)
runs on `--target jvm` in CI going forward.

Also removed `lyric-i18n/README.md`'s now-stale `**Note (#7458):**
I18nKernelTests is a known pre-existing failure on --target jvm` line
(added by an earlier commit on this branch while the bug was still
open); the bug is fixed, so the note no longer applies. The README's
"Quick start" / "API reference" / "Configuration" / "File-backed store"
sections the task described as referencing `NativeTranslationStore` /
`I18nConfig` / `loadNative` / `ParsedLocale` had already been rewritten
against the shipped public surface by an earlier commit on this branch
(`dde40c84`, #7471); none of those names appear in `src/i18n.l` or the
current README, and there is no `## Configuration` section. Verified
the README's remaining code blocks compile against the shipped API on
both `--target dotnet` and `--target jvm`.
