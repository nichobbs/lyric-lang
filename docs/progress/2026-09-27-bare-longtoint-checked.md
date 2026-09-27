# 2026-09-27 — Bare `longToInt` reaches the checked `Std.Math.longToInt`

D-progress-1004, #7465.

With `import Std.Math`, a bare `longToInt(3_000_000_000i64)` used to return
`-1294967296` on dotnet and the JVM: both backends lowered the bare name to
an unchecked conversion before name resolution, so the function's
`requires:` never ran. Native, which had no such intercept, already failed
the precondition. All three targets now fail with
`PreconditionViolated: Std.Math.longToInt requires ...`.

The MSIL and JVM intercepts for `longToInt`, `intToLong`, `charToInt` and
`intToDouble` are gone; these names resolve like any other (package
declaration, then import). Compiler, stdlib-kernel and ecosystem call sites
that wanted the wrap-around now use `.toInt()` / `.toLong()`, which the
language reference already defines as the truncating conversions.

Tests:

- `lyric-compiler/lyric/conversion_name_resolution_self_test.l` (new, CI on
  dotnet and JVM): bare and qualified `longToInt` in range and out of range,
  bare `intToLong`, `.toInt()` wrapping, and a package's own `charToInt`/
  `intToDouble` being called.
- `lyric-stdlib/tests/math_tests.l`: bare-call cases; now also run on the JVM.
- `scripts/ci/native-target-smoke-test.sh`: native has no try/catch, so a
  program checks the in-range values and the precondition failure from the
  outside.
