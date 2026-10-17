# D-progress-1052: float-to-integer conversions saturate on every target

**Status:** shipped (closes #8375, #8376)

## Decision

1. `.toInt()`, `.toLong()`, `.toByte()` and `.toNat()` on a `Double` or `Float` whose
   truncated value is outside the target type saturate to that type's minimum or maximum,
   and NaN converts to `0`. `.toByte()` saturates to the `Long` range before keeping the low
   8 bits, so `1e300.toByte()` is `255`. `.toNat()` still panics on a negative value or NaN;
   above its range it saturates to `Long.MAX` like `.toLong()`.
2. This is what .NET (9 and later; the compiler targets `net10.0`) and the JVM (`d2i`/`d2l`)
   already did, verified on both. The native backend emitted a plain `fptosi`, whose result
   for an out-of-range value is LLVM poison (it returned `0` in practice). Every `NFPToSI`
   now renders as a call to `llvm.fptosi.sat.i32.f64` / `llvm.fptosi.sat.i64.f64`, declared
   with the runtime declarations, so the rule holds wherever native converts a float.
   `.toChar()` range-checks before converting and is unaffected.
3. Option 2 of #8375 (making these checked conversions that panic) was rejected: the
   language reference already says the conversion methods other than `.toChar()` and
   `.toNat()` never fail, and two of the three targets already saturate.
4. #8376: a test pins that `Std.Http`'s bundled client impl is lowered when its
   constructing function is called through an import alias (`H.defaultClient()`,
   `H.HttpClientBuilder.new()...build()`) or a fully qualified path. Both already worked;
   no code change was needed. `HttpClientImpl` is private to `Std.Http`, so construction
   from another package is not reachable from user code.

## Tests

`conv_methods_self_test.l` (dotnet and JVM): huge, negative, infinite and NaN `Double`
receivers and an out-of-range `Float` for `.toInt()`, `.toLong()` and `.toByte()`.
`llvm_stdlib_self_test.l` (native, ASan): the same cases plus `.toNat()`, the alias and
qualified `Std.Http` constructions, and a guarded `match` arm whose value is a bare `None`
(the review suggestion on #8374).
