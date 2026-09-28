# D-progress-1024 — Backend builtin dispatch follows the type checker's own resolution (#7508)

**Status:** shipped

Supersedes the "a *user* package declaring its own function with one of
these names: the bare call is still intercepted [...] left as a follow-up"
caveat in D-progress-1004 (#7465).

## Problem

Both backends' `lowerBuiltinOrStaticCall{Msil,}` dispatchers (MSIL:
`msil/codegen.l`; JVM: `jvm/codegen/04_calls.l`) matched the remaining
intercepted names — `newList`, `newListWithCapacity`, `newMap`, `newSet`,
`mapGet`, `tryGetValue`, `dictGetKeys`, `dictGetValues`,
`hostGetCommandLineArgs`, `stringToUtf8Bytes`, `charToString`, `catch`,
`println`, `print`, `panic`, `assert`, `toString`, `default`, `format1`-
`format4`, `hashCode`, `__lyric_protected_wait`, `__lyric_protected_notify`
— by STRING, before any name resolution ran. MSIL had a partial guard
(`hasQualifiedFuncOverrideMsil`, #5084) but it only covered explicitly
QUALIFIED (2+-segment) calls; JVM had no guard at all. A package's own bare
function sharing one of these names was silently uncallable — every bare
call site was captured by the intrinsic instead, and the user's function
was never invoked. `--target native` (`lyric-compiler/lyric/llvm_codegen.l`)
had the identical gap for its own bare-only intercept subset (`mapGet`,
`dictGetKeys`, `dictGetValues`, `newList`/`newListWithCapacity`/`newMap`).

## Decision

1. **A bare or qualified call resolves to what the type checker's own
   scope rules (docs/01 §9.2, D141) resolve it to.** Each backend now
   computes, at the same dispatch point, whether the call ALSO resolves to
   a real registered function through the exact registry an ordinary
   (non-intercepted) call would use — `funcTokens`/`bareImportListForNameMsil`
   on MSIL (`hasFuncOverrideMsil`), the cross-package `funcSigs` registry via
   `resolveGeneralFuncSig` on JVM (`hasFuncOverrideJvm`), and the
   non-generic `sigs` registry on native (`hasFuncOverrideNative` — the
   `Std` functions these intrinsics implement are all GENERIC and so never
   appear there, meaning only a genuine non-generic override can ever
   match). This mirrors resolution the compiler already performs elsewhere
   for real calls, rather than re-deriving it from the call's spelling.
2. **Two disjoint tiers**, per the D-progress-1004 audit:
   - **Stdlib-kernel names** (`newList`, `newListWithCapacity`, `newMap`,
     `newSet`, `mapGet`, `tryGetValue`, `dictGetKeys`, `dictGetValues`,
     `hostGetCommandLineArgs`, `stringToUtf8Bytes`, `charToString`,
     `catch`) have a genuine `Std.*` declaration with IDENTICAL semantics
     to the intrinsic. A call (bare or qualified) that resolves to that
     `Std.*` declaration keeps using the fast intrinsic path — routing it
     through the general call registry instead is pure overhead and, for
     an erased-generic kernel extern with no genuinely callable concrete
     signature, can misresolve (hit during implementation: JVM's
     `Std.CollectionsHost.newMap()` called qualified through the general
     registry threw `NoSuchMethodError` — the erased generic descriptor
     never matches the intrinsic's assumed shape). Only a resolution to a
     NON-`Std` declaration (this package's own, or a bare-imported/
     explicitly-qualified non-`Std` package's) bypasses the intrinsic.
   - **True language built-ins** (`println`, `print`, `panic`, `assert`,
     `toString`, `default`, `expect`, `format1`-`format4`, `hashCode`,
     `__lyric_protected_wait`, `__lyric_protected_notify`) have NO ordinary
     Lyric signature — `println`'s argument is polymorphic over any type,
     `panic` returns `Never` — so a `Std.*` package's own same-named
     function (`Std.Console.println(s: String)`) is always a genuinely
     DIFFERENT function, never a redundant reimplementation. These are now
     **reserved**: a non-`Std.*` package's `func`/`pub func` declaration
     under one of these names is rejected at declaration time as **T0140**
     (`typechecker_checker.l`'s `checkReservedBuiltinFuncDecl`), rather
     than silently shadowing or being silently captured. Because
     redeclaration outside `Std.*` is now a compile error, the bare
     dispatch tier needs no Std-exclusion check for these names — a
     non-`Std` bare match can never exist — but the QUALIFIED tier still
     does: an explicitly-qualified call to ANY registered function under
     one of these names (Std-owned or not) always overrides, exactly
     mirroring the original #5084 `Std.Http.Url.toString` fix this
     generalizes.
3. **`Std.*` origin exemption.** `isStdOriginPkg` (`originPkg == "Std" or
   originPkg.startsWith("Std.")`) is the same test both the bare-override
   loops and the reserved-name diagnostic use. `Std.Console` already ships
   real `println`/`print` functions (String-only, reachable only
   qualified per the `isCodegenBuiltinName` import-time skip
   `typechecker_checker.l` already had) — T0140 does not fire for them.

## Verification

`conversion_name_resolution_self_test.l` (both targets, wired into CI
already) extended with: a package-local `newList`/`newMap` of a DIFFERENT
arity than the stdlib generics, proving a bare call reaches the local body;
the real (non-overridden) `Std.Collections.newListWithCapacity`/`mapGet`
still work bare; and a qualified `Std.CollectionsHost.newMap()` call
(exercising the tier-B qualified-Std-stays-on-intrinsic rule, and the bug
found during implementation). `typechecker_self_test.l` covers T0140:
firing for `println`/`toString`/`hashCode` outside `Std.*`, NOT firing for
a `Std.*` package, and NOT firing for a non-reserved name like `newList`.

## Follow-ups

- The "an imported (not same-package) NON-`Std` package declares one of
  the stdlib-kernel names" scenario is covered by code review (the same
  `bareImportListForNameMsil`/`resolveGeneralFuncSig` primitives dozens of
  other self-tests already exercise for ordinary cross-package bare
  calls) rather than a dedicated new self-test: `lyric test`'s single-file
  v1 runner (docs/24-test-runner-plan.md) cannot compile a second,
  separately-imported sibling package alongside the test file without
  that package being part of the prebuilt compiler bundle. A
  manifest-driven multi-package runtime test on all three targets is
  tracked in #7675.
- On `--target jvm`, calling an erased-generic kernel extern such as
  `Std.CollectionsHost.newMap()` through the general call registry links
  the wrong descriptor (`NoSuchMethodError`). This fix keeps every
  `Std`-resolved call to a stdlib-kernel name on the intrinsic path, so no
  program reaches that path today; the descriptor bug itself is tracked in
  #7674.
