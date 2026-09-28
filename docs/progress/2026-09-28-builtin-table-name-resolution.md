# 2026-09-28 — Backend builtin dispatch follows the type checker's own resolution (#7508)

D-progress-1024, #7508. Follow-up to D-progress-1004 (#7465).

`#7465` removed the four conversion-name intercepts (`longToInt`,
`intToLong`, `charToInt`, `intToDouble`) but left the rest of MSIL's and
JVM's builtin-call tables matched by string before name resolution:
`newList`, `mapGet`, `tryGetValue`, `newSet`, `toString`, `hashCode`,
`println`, `panic`, and others. A user package declaring its own function
under one of these names had every bare call to it silently captured by
the backend intrinsic instead — the user's function was never called.
`--target native` had the identical gap for its own bare-only intercept
subset.

- MSIL (`lyric-compiler/msil/codegen.l`): `hasQualifiedFuncOverrideMsil`
  (the #5084 guard, previously qualified-calls-only) is now
  `hasFuncOverrideMsil`, covering bare calls too — a same-package
  declaration, or a bare-imported non-`Std` package's declaration, wins
  over the intrinsic.
- JVM (`lyric-compiler/jvm/codegen/04_calls.l`) had no override guard at
  all; `hasFuncOverrideJvm` now resolves every intercepted name through
  `resolveGeneralFuncSig` (the same registry an ordinary call uses) before
  falling back to the intrinsic.
- Native (`lyric-compiler/lyric/llvm_codegen.l`): `hasFuncOverrideNative`
  guards the `mapGet`/`dictGetKeys`/`dictGetValues`/`newList`/
  `newListWithCapacity`/`newMap` bare intercepts against the non-generic
  `ctx.sigs` registry (the `Std` functions these intrinsics implement are
  all generic and so never appear there).
- A resolution to the exact `Std.*` function the intrinsic implements
  (bare OR qualified) still uses the fast intrinsic path — behaviorally
  identical per D-progress-1004's audit, and required on JVM: routing a
  qualified `Std.CollectionsHost.newMap()` call through the general
  registry hit a real, pre-existing signature-linking gap for calling an
  erased-generic kernel extern directly (`NoSuchMethodError`), discovered
  during implementation and avoided by keeping `Std`-resolved calls on the
  intrinsic path regardless of spelling.
- A second, disjoint set of names (`println`, `print`, `panic`, `assert`,
  `toString`, `default`, `expect`, `format1`-`format4`, `hashCode`,
  `__lyric_protected_wait`, `__lyric_protected_notify`) have no ordinary
  Lyric signature at all and are now reserved: a non-`Std.*` package's
  `func`/`pub func` declaration under one of these names is **T0140**
  (`typechecker_checker.l`'s `checkReservedBuiltinFuncDecl`). `Std.*`
  keeps the exemption `Std.Console.println`/`print` (real, String-only,
  qualified-only functions) already relied on.

Verified by `conversion_name_resolution_self_test.l` (extended, both
targets, already wired into CI) and `typechecker_self_test.l`'s new T0140
cases. `docs/01-language-reference.md` §9.2 documents the rule; see
D-progress-1024 for the full design and the follow-up on testing a
cross-package (imported, non-`Std`) override, which single-file `lyric
test` cannot exercise directly.
