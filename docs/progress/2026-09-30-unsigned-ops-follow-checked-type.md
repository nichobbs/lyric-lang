# Unsigned operations follow the checked type, not the operand's shape (#7812)

`UInt` and `ULong` lower to the same representation as `Int` and `Long` on
both targets (`int32`/`int64` on dotnet, `int`/`long` on the JVM).
Stringification, the ordering operators (`<`, `<=`, `>`, `>=`), division and
remainder must therefore be told that an operand is unsigned.

The backends used to guess this from the operand's syntax. `isUnsignedExprMsil`
recognised bare locals, parameters, `u32`/`u64` literals and `.toULong()`.
The JVM's `isUnsignedExpr` also recognised bare-name calls and index reads off
a bare-name receiver. Anything else was treated as signed: a record field read
on both targets, a slice element on dotnet, a method or function-value
result, a generic instance's field, a `Map` value, a match binding, and a
closure-captured `var` on dotnet. A value with its top bit set then printed,
compared, divided and took its remainder as a negative number:

```lyric
record Holder { v: ULong }
val h = Holder(v = 9223372036854775807u64 * 2u64 + 1u64)
println(h.v)        // printed -1; now 18446744073709551615
println("${h.v}")   // printed -1; now 18446744073709551615
```

Compound `/=` and `%=` used signed division for every `UInt`/`ULong` target
on both targets, including a bare local.

## Fix

The type checker now decides. `recordUnsignedOperand` records each operand
whose checked type is `UInt`/`ULong` at a position whose lowering depends on
signedness. These are the positions:

- an argument of `println`, `print`, `toString` or `format1`–`format4`;
- a `.toString()` receiver;
- an interpolated segment;
- the right operand of a `String` `+`, and the value of a `String` `+=`;
- an operand of `<`, `<=`, `>`, `>=`, `/` or `%`;
- the value of a `/=` or `%=` on an unsigned target.

It uses the existing span-keyed `argConversionSites` channel (#7805).
`Lyric.Mono.desugarCheckedFile` then rewrites each recorded operand to the
identity `.toUInt()` / `.toULong()` before any backend runs. A widening
already recorded at the same operand wins, since it converts to `ULong`,
which is unsigned too.

A generic body is checked only once, over its type parameters. So `Lyric.Mono`
applies the same positions to each specialisation whose type arguments
mention `UInt`/`ULong`, using the types the specialisation's parameters and
locals now declare (`spellUnsignedSitesMono`).

Each backend's unsigned test now recognises only two things: a `u32`/`u64`
literal, and a `.toUInt()`/`.toULong()` call. The following were removed:

- the MSIL `fctx.unsignedSlots` map;
- the JVM `ctx.unsignedVars` map and its `unsignedUndo` scope log;
- the JVM `JvmFuncSig.retIsUnsigned` and `varGenericArgs` guesses.
  `retIsUnsigned` remains only for a distinct type's `$value` accessor.

`.toUInt()` is a user-facing conversion now too: the `Byte < UInt` widening,
on `Byte` and `UInt` receivers, and `T0103` elsewhere (including `ULong`,
which would narrow). A `Byte` argument to a function value's `UInt` parameter
therefore converts, where it used to be rejected with `T0043`. Each target
lowers the two conversions from these receivers:

- a boxed receiver (a JVM generic payload, element or function-value result),
  unboxed from its `Long`, `Byte` or `Integer` box and zero-extended;
- on dotnet, `div.un`/`rem.un` in `emitCompoundCombineMsil` and
  `emitCompoundCombineSlotMsil`;
- on the JVM, `Integer`/`Long.divideUnsigned`/`remainderUnsigned` in
  `emitCompoundArith`.

## Tests

The new `unsigned_typed_ops_self_test.l` runs on both targets (13 cases). It
uses `UInt` values of at least 2^31 and `ULong` values of at least 2^63. Each
of these sources goes through `toString`, interpolation, `.toString()`,
`String +`, `<`, `<=`, `>`, `>=`, `/` and `%`:

- record field reads, slice elements, `List` elements and `Map` values;
- function, method, generic-call and function-value results;
- `Box[ULong]`/`Box[UInt]` fields, tuple elements and match bindings;
- compound `/=`, `%=` and `+=`;
- monomorphised generic bodies and a closure-captured `var`;
- `.toUInt()`, plus signed control cases.

It is wired into `scripts/ci/compiler-self-tests-batch.sh` (dotnet),
`scripts/ci/jvm-generics-self-tests-batch.sh` (JVM) and
`scripts/ilverify-selfhosted.sh` phase 4. `typechecker_self_test.l` covers:

- `.toUInt()` acceptance and its `T0103` rejections;
- the conversion sites recorded for unsigned operands, and none for signed or
  sign-independent ones;
- the `Byte`-to-`UInt` function-value conversion.

Native has no `UInt`/`ULong` representation (`typeExprToNType` rejects both),
so it has nothing to lower here.

## Not fixed here

- A `u64` literal above `Long`'s range (`18446744073709551615u64`) is rejected
  by the lexer (`L0010`), so the tests compute 2^64 - 1.
- The JVM `format1`–`format4` builtins return their template unformatted.
- An unsuffixed literal is not adopted as the target type of a compound
  assignment: `x %= 7` on a `UInt` `x` is `T0063`.
- Match patterns over a `UInt`/`ULong` scrutinee (range patterns) are not
  among the positions above.
