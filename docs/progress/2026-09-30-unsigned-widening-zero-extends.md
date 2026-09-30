# Implicit UInt to ULong widening zero-extends on every target (#7805)

docs/01 §4.1 makes `Byte < UInt < ULong` a lossless implicit widening chain,
but both backends lower a `UInt` to the same 32-bit representation as an
`Int` (`int32` on dotnet, `int` on the JVM), so an implicit `UInt` to `ULong`
widening at a binding, argument, constructor argument, `=` or `op=` emitted a
sign extension (`conv.i8` / `i2l`). A `UInt` with its top bit set came out
wrong: `var ul: ULong = 1u64; ul += 4000000000u32` gave
18446744073414584321 instead of 4000000001, and `val a: ULong = u` with
`u = 4000000000u32` gave 18446744073414584320. The mixed-width operator paths
(#7350, #7382) recovered the operand's signedness from its syntax alone, so a
`UInt` record field beside a `ULong` was sign-extended there too.

The type checker now spells every implicit widening to `ULong` out as
`.toULong()`. It records the widened expression as a conversion site (the
existing `argConversionSites` channel), and `Lyric.Mono.desugarCheckedFile`
rewrites it before any backend runs, so each backend lowers one explicit
conversion: `conv.u8` on dotnet, `Integer.toUnsignedLong` on the JVM. The
sites are:

- `val`/`var`/`let` initialisers, `=` and every compound `op=`, on locals,
  fields and indexed elements;
- arguments of direct, method and generic calls (with the generic
  parameters bound from the call), calls through a function value,
  record and union-case constructor arguments, `.copy(...)` fields, and
  `List.add` / `Map.add` elements, keys and values;
- operands of mixed-width arithmetic and ordering operators;
- a value-producing `if`/`match` branch checked against an expected type.

`.toULong()` is also a user-facing conversion method now, on `Byte`, `UInt`
and `ULong` receivers; on any other primitive it is `T0103`. It is the
conversion a call through a function value needed for a `Byte` or `UInt`
argument to a `ULong` parameter, which is accepted now instead of `T0043`
(a `Byte` for a `UInt` parameter still has no conversion and stays `T0043`).
The backends' unsigned-expression tests recognise a `.toULong()` call, so the
widened operand keeps unsigned comparison and division.

The checker also accepted the widening at a binding but rejected it at a
`return` (`T0065`), as a function body's value (`T0070`), and as an element
of a slice literal (`T0060`/`T0041`). A returned value, a body's value and a
literal element initialise a slot of the declared type, so docs/01 now lists
them with the other positions and the checker accepts them. These positions
had no backend widening at all, so every widening there is recorded, the
signed chain included (`.toLong()`, `.toInt()`, `.toULong()`); a
value-producing branch records every widening too, which also fixes a JVM
`VerifyError` for `val x: Long = if c { i } else { l }` with `i: Int`.

The new dual-target `unsigned_widen_self_test.l` covers each position with
values of at least 2^31, plus `Byte` sources, the signed chain at the newly
accepted positions, and `.toULong()` itself. It runs in CI on both targets
beside `mixed_width_unsigned_self_test.l`, and both are now verified by
`scripts/ilverify-selfhosted.sh` phase 4. `typechecker_self_test.l` covers
the return and slice-literal acceptance and the `T0103` rejection.

Native has no `UInt`/`ULong` representation yet, so it has no unsigned
widening to lower.

Not fixed here:

- Module-level `val`, record field default and parameter default
  initialisers are not checked against their declared type at all, so no
  widening is recorded there either (`val g: ULong = someUInt` still
  sign-extends).
- A `UInt`/`ULong` value read from a record field, or on dotnet from a slice
  element, still prints, compares and divides as signed when its top bit is
  set: both backends decide an expression's signedness from its syntax
  (`isUnsignedExprMsil`, `isUnsignedExpr`), which sees only locals,
  parameters, literals and (on the JVM) bare-name calls and index reads.
