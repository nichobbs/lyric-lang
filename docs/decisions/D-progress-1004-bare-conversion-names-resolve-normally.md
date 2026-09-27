# D-progress-1004 — Bare conversion-function names resolve like any other name (#7465)

**Status:** shipped

Supersedes the "bare `longToInt(n)` still lowers to an unchecked truncation"
caveat in D-progress-998, and the bare-call half of D-progress-849 (#6712).

## Problem

Both backends' `lowerBuiltinOrStaticCall` dispatchers intercepted the bare
names `longToInt`, `intToLong`, `charToInt` (MSIL) and `intToDouble`, and
lowered them straight to `conv.i4`/`l2i`, `conv.i8`/`i2l`, a no-op, and
`conv.r8`/`i2d`. The intercept ran before name resolution, so:

- `import Std.Math` + bare `longToInt(3_000_000_000i64)` returned
  `-1294967296` on dotnet and the JVM instead of failing
  `Std.Math.longToInt`'s `requires:` (native had no intercept and already
  failed the precondition, so the three targets disagreed);
- a package's own function with one of those names (for example
  `lexer.l`'s `longToInt`) was never called.

#6712 had only exempted qualified calls (`Std.Math.longToInt`,
`Math.longToInt`).

## Decision

1. **No new intrinsic name.** The explicit truncating/widening conversions
   already exist as the documented `.toInt()` / `.toLong()` / `.toDouble()`
   methods (language reference §4.1: narrowing truncates).
   Adding `truncateToInt`/`widenToLong` would be a second spelling of the
   same operation.
2. **Delete the four bare-name intercepts** on MSIL and JVM (and the now
   unused `hasQualifiedFuncOverrideJvm`). A bare `longToInt` now resolves
   through the normal scope rules: a declaration in the current package,
   otherwise an import — for `import Std.Math`, the checked
   `Std.Math.longToInt`. With no declaration in scope the call is an
   ordinary unknown-name error rather than a silent built-in.
3. **Migrate every internal call site that relied on the intercept** to the
   method form, preserving its exact (truncating) behaviour:
   `msil/codegen.l`, `msil/lowering.l`, `jvm/lowering.l`,
   `jvm/codegen/{02_exprs,03_match,06_items}.l`, `lexer.l`,
   `llvm_codegen.l`, the `_kernel_jvm` `task`/`http_server`/
   `process_capture_host`/`process_piped_host` kernels, `lyric-storage`
   and both `lyric-auth` kernels. Several compiler sites (`UInt` range
   bounds above `Int32.MaxValue`, `u32` literals) depend on the wrap to the
   low 32 bits, so they must not move to the checked function.
   `lexer.l`'s O(n) loop-based `longToInt`/`intToLong` helpers and
   `llvm_codegen.l`'s `intToLong` wrapper are deleted.

## Other intercepted names

The remaining names in the two dispatchers were audited for the same
hazard (an intercept whose semantics differ from a function the caller
declared or imported):

- `println`, `print`, `panic`, `assert`, `toString`, `default`, `format1`–
  `format4`, `hashCode`, `__lyric_protected_*`: language-level built-ins.
- `newList`, `newListWithCapacity`, `newMap`, `newSet`, `mapGet`,
  `tryGetValue`, `dictGetKeys`, `dictGetValues`, `hostGetCommandLineArgs`,
  `stringToUtf8Bytes`, `charToString`, `catch`: the intercept implements
  the same-named stdlib kernel function with the same semantics, so a call
  that resolves to that function behaves identically.

No other intercept changes the meaning of a call that resolves to a
stdlib function. The residual hazard is a *user* package declaring its own
function with one of these names: the bare call is still intercepted. That
is a separate, broader change (resolve local declarations before the
built-in table) and is left as a follow-up.
