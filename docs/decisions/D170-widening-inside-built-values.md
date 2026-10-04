# D170 — Lossless widening applies inside a value being built, not to a built value

**Status:** accepted, implemented (#7813)

## Context

docs/01 §4.1 makes `Byte < Int < Long`, `Byte < UInt < ULong` and
`Float < Double` implicit lossless widening chains. After #7805 a narrower
scalar widened at every *direct* position: a binding, an assignment, an
argument, a `return`, a body's value, a non-generic record field, a
list or slice literal element. It did not widen one level down: with
`u: UInt`, `val a: Option[ULong] = Some(u)` and `val b: (ULong, Int) = (u, 1)`
were T0060, because `Some(u)` was typed bottom-up as an `Option[UInt]` and
`(u, 1)` as a `(UInt, Int)`, and neither is a `ULong`-carrying type.

#7813 asked whether the rule should reach through generic constructor
arguments and tuple elements where the expected type is known.

## Decision

1. **Yes, for a scalar in a value being built.** A constructor argument of
   a generic instance (`Some(...)`, `Ok(...)`, `Err(...)`, a generic record
   or union case, bare, qualified or with named arguments) and a tuple
   element initialise a slot whose type the expected instantiation fixes, so
   the scalar widens to it like any initialiser. This holds at any nesting
   (`Some((u, 1))` where an `Option[(ULong, Int)]` is expected,
   `[(u, 1)]` where a `List[(ULong, Int)]` is) and in every position that
   has an expected type: an annotated binding, an assignment, a call
   argument, a record field, a `return` and a body's value.

2. **No, for a value already built.** `val p: Option[ULong] = o` with
   `o: Option[UInt]` stays T0060. That is covariance over values whose
   representation is already fixed (a reified `Option<uint>` on dotnet, a
   boxed `Integer` on the JVM), not a scalar widening, and converting it
   would mean an implicit traversal and reallocation. The diagnostic says
   so and names the rebuild (`mapOption(o, { x -> x.toULong() })` for an
   `Option`, `mapResult` / `mapResultErr` for a `Result`, the conversion
   method otherwise).

3. **Every chain is spelled out.** The checker pushes the expected slot type
   into each argument (`inferExprExpected`), types a widening argument at
   the slot type, and records it as a conversion site of its chain
   (`.toLong()`, `.toInt()`, `.toDouble()`, `.toUInt()`, `.toULong()`) —
   signed and float chains included, unlike #7805's direct positions where
   only the unsigned chain needed it. `Lyric.Mono` rewrites the argument
   before any backend runs. A generic slot is reified at the argument's own
   type on dotnet and boxed on the JVM and native, and a tuple element is a
   field of a tuple of the argument's type, so no backend could widen the
   scalar there from the operand types; with the conversion in the source
   each backend builds the instance at the expected type, and the unsigned
   chain zero-extends (`4000000000u32` stays `4000000000`).

## Consequences

- No new syntax and no new diagnostic code; T0060 at an existing container
  value gains the hint above.
- A call argument that builds a value (a case constructor, a generic record
  constructor or a tuple literal) is re-checked against the selected
  parameter type when it differs from it only by such widenings, so
  `takesOpt(Some(i))` for a `takesOpt(o: in Option[Long])` is accepted.
- An inline range type in the expected instantiation is still checked
  (#8031): a union-case payload, a generic record field and a tuple element
  whose slot is a range record a range site beside any widening of another
  slot (`Duo(wide = i, narrow = n)` where a `Duo[Long, Int range 0 ..= 3]`
  is expected). A scalar does not widen *into* a range type, at a direct
  position or inside a built value: `Long range 0 ..= 3` takes a `Long`.
- Native has no unsigned integer types yet, so the unsigned half is covered
  on dotnet and the JVM (`generic_ctor_unsigned_widening_self_test.l`), the
  signed and float halves on all three targets
  (`generic_ctor_widening_self_test.l`).
