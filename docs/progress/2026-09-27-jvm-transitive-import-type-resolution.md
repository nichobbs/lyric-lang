# JVM: bare cross-package type references now resolve through transitive imports (#7357)

`Jvm.Bridge.externSeedForFile`'s bare-key visibility check considered only a
consumer file's own DIRECT imports when deciding which packages' declared
types a bare (unqualified) type reference could resolve against. A file
that writes `import Std.Json` — never `import Std.JsonHost`, the package
that actually declares the plain record `pub record JsonElement`, re-exported
through `Std.Json` — or `import Std.Time` — never `import Std.TimeHost`,
which declares `extern type Instant = "java.time.Instant"`, re-exported
through `Std.Time` — had no DIRECT import naming the declaring package, so
the bare name fell through to the "declared in my own package" guess
(`<consumer pkg>/JsonElement` / `<consumer pkg>/Instant`), a nonexistent
class. Loading it threw `NoClassDefFoundError` at class-load, surfacing at
runtime (not compile time) for:

- a plain function parameter naming the type (`Lambda.Dispatch.hasProp(elem:
  in JsonElement, name: in String): Bool`, called from a sibling function —
  #7337's follow-up investigation; `lyric-i18n`'s `fromJson` carried an
  inlining workaround for the identical gap, documented in its own header
  comment).
- a lambda parameter naming the type.
- a `Lyric.Mono`-monomorphised generic function's substituted parameter type
  (`Std.Core.isSome[T]` called with `o: Option[Instant]` synthesises a
  specialised copy whose parameter becomes a bare `TRef("Instant")`,
  registered as if declared in the caller's own file).

A SECOND, related gap surfaced once the first was fixed: `lyric-lambda`'s
`lambda_aspect_weaving_tests.l` (a `DeadlineGuard` aspect declared `around(call)
-> ret where TArgs has { ctx: Lambda.LambdaContext }`, docs/56's row-
constrained B'-mode) still failed with `NoClassDefFoundError:
Lambda/AspectWeavingTests/LambdaContext` — a QUALIFIED reference this time,
not a bare one. `Jvm.Bridge.collectWovenSigsMatching` (registering the sigs
of `__aspect_*`/`__lyric_bmode_*` weaver-synthesised functions, so a
per-match wrapper's call to them resolves to the real descriptor instead of
the `(…)Object` guess, #3402/#4600) erased every parameter/return type
through the PLAIN `typeExprToJvm` — no `externTypes` map at all, not even
the qualified-key tier — so even a fully-qualified `Lambda.LambdaContext`
lost its qualifier and erased to "declared in my own package".

## Fix

- `Jvm.Bridge.transitiveWantedPkgs` (`lyric-compiler/jvm/bridge.l`) computes
  the full transitive closure of package names a file can reach through
  imports — its own imports, then each of those packages' own imports, and
  so on — via a BFS over a new `pkgImportNames: Map[String, List[String]]`
  (each in-bundle package's own import list, built alongside the existing
  `extPkgNames`/`extPkgMaps` construction). `externSeedForFile` now computes
  its bare-key `wanted` set through this closure instead of `file.imports`
  alone, so `Std.JsonHost`/`Std.TimeHost` count as "wanted" for any file
  that reaches them transitively through `Std.Json`/`Std.Time`.
- `Jvm.Bridge.collectWovenSigsMatching` now takes an `externTypes` map and
  resolves every parameter/return type through `typeExprToJvmExtern` instead
  of the plain `typeExprToJvm`, threaded from the SAME `externSeedForFile`
  call every sibling woven-sig collector already uses. `collectAspectWovenSigs`/
  `collectBModeWovenSigs` (and their 4 call sites) now pass it through.

## Tests

`lyric-compiler/jvm/cross_package_type_resolution_jvm_self_test.l` (3 cases,
both targets): a plain function parameter, a lambda parameter, and
`Option[Instant]`/`isSome`, each naming a type reached only transitively.
Batched into CI with 3 sibling generic/cross-package self-tests via
`scripts/ci/jvm-generics-self-tests-batch.sh` (one CI step for all four,
keeping `.github/workflows/ci.yml` under the byte ceiling
`scripts/ci/check-workflow-size.sh` enforces).

`lyric-i18n`'s `fromJson` no longer needs its inlining workaround: the
per-locale JSON walk is now a proper helper,
`decodeLocaleTranslations(localeVal: in JsonElement, ...)`, taking the
`JsonElement` directly as a parameter. Verified on both targets (63/63
`I18n.I18nTests`; `I18n.I18nKernelTests` has a pre-existing, unrelated
`--target jvm` type-checker failure reproduced identically on `main`).

`lyric-lambda`'s full suite (`LambdaTests` 40/40, `DispatchTests` 40/40,
`AspectWeavingTests` 3/3) now passes on `--target jvm`, wired into CI via
`scripts/ci/manifest-jvm-maven-test.sh`. Regression-swept lyric-storage,
lyric-resilience, and lyric-health on `--target jvm`: all clean.
