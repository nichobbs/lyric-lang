# Unsigned match patterns and specialised generic bodies (#7842)

#7812 made the type checker decide which `UInt`/`ULong` operands compare,
divide and print unsigned. Two kinds of position were left outside it.

## Match patterns

A range pattern against a `UInt`/`ULong` scrutinee compared signed on both
targets. `case 0u32 ..= 3000000000u32` read its upper bound as a negative
`Int`, so the range was empty and `5u32` fell through. A literal pattern
fared no better:

- an unsuffixed `case 4000000000` against a `UInt` loaded a 64-bit constant
  for a 32-bit scrutinee on dotnet;
- on the JVM a `u32` literal above 2^31 compared as a `long` against an `int`
  scrutinee, which fails verification;
- an unsuffixed literal against a `ULong` loaded a 32-bit constant on dotnet.

Patterns now follow the scrutinee's type:

- **Type checker.** `bindPatternTyped` types each literal pattern and each
  range bound against a `Byte`/`UInt`/`ULong` scrutinee, including one
  nested in a constructor, tuple or record pattern.
  - An unsuffixed literal or bound that fits takes the scrutinee's suffix, as
    an initialiser does (#7841).
  - A `UInt`/`ULong` bound of any other shape, a named `val` say, is
    recorded as an unsigned operand.
  - A literal or bound the type cannot hold (`case -1` on a `UInt`) is
    **T0015**.
- **`Lyric.Mono`.** `rewritePatternSitesMono` applies those sites to match-arm
  patterns. Until now, `argConversionSites` were applied to expressions only.
- **MSIL.** A range whose bound spells unsigned (a `u32`/`u64` literal or
  `.toUInt()`/`.toULong()`) uses `clt.un`/`cgt.un`. A boxed tuple-element
  scrutinee unboxes at the width a `.toULong()` bound denotes.
- **JVM.** Such a range orders through `Integer`/`Long.compareUnsigned`, and a
  `u32` literal pattern compares as the `int` holding its 32-bit pattern.
- **Native.** Only `Byte` lowers. Its range tests now use the unsigned
  `icmp` predicates its comparisons already used (#4628), so `case 200 ..=
  255` matches `250u8`.

## Specialised generic bodies

A generic body is checked once, over its type parameters, so an operand
typed `T` is known to be unsigned only in a specialisation. #7812 handled
that in `Lyric.Mono` (`spellUnsignedSitesMono`) with Mono's own local type
inference. Where that inference fell short, the operation stayed signed. A
closure result is one case: `"${f(x)}"` with `f: (T) -> T` and `T = UInt`
printed `4000000000` as `-294967296`.

The checker now types each such specialisation itself:

- `Lyric.Mono` reports every specialisation whose type arguments mention
  `UInt`/`ULong` in `MonoResult.unsignedSpecs`.
- `Lyric.Pipeline.recheckUnsignedSpecs` type-checks each one as the
  non-generic function it is (`Lyric.Mono.specializeFuncDecl`: the generic
  with its type arguments substituted throughout). It checks it in the scope
  of the package declaring the generic. For this file that is the file
  itself, and the original generic declaration is used, not the desugared
  one. For another package it is that package's items and imports, plus its
  private generics. The scope's other functions are checked as signatures
  only, as `@axiom`s with their bodies removed, so a re-check costs one body.
- The conversions the checker records in the specialised body are passed back
  as `specSites`, and Mono specialises again with them. They include unsigned
  operands, widenings and literal suffixes, whether `T` reached the operand
  through a parameter, a field, a method or function-value result, or a
  closure. A conversion that the generic's own desugaring already applied is
  recognised and not applied twice.
- `spellUnsignedSitesMono` and its inference-based helpers are removed.

A specialisation that cannot be checked is **M0007**, not compiled signed.
That happens when its body reports an error once its type arguments are
substituted, or when the package declaring the generic is not in the build's
scope.

## Tests

- `typechecker_self_test.l`: the suffix sites recorded for literal and range
  patterns on `UInt`, on a nested `ULong` and on `Byte`; a named bound
  recorded as an unsigned operand; T0015 for `case -1`, `case -5 ..= 3` and a
  `Byte` pattern of `256`; no sites for a signed scrutinee.
- `unsigned_typed_ops_self_test.l`, dotnet and JVM:
  - range and literal patterns with unsuffixed and suffixed bounds at and
    above 2^31 and 2^63, including inclusive and exclusive edges, a named
    bound, a nested `Some(...)` range, a range on a tuple element, and `Byte`;
  - generic bodies whose `T` operand comes through a field (`>`, `<=`, `/`,
    `%`), a method result and a closure result (interpolation, `toString`,
    `.toString()`) and a closure capture, for `UInt` and `ULong`, with `Int`
    controls;
  - `Std.Sort.sort` over a `slice[UInt]`, which re-checks a specialisation of
    a stdlib generic.
- `byte_native_self_test.l`, native: `Byte` range and literal patterns.

## Not fixed here

- Comparison and arithmetic operators on a bare type parameter are rejected
  even under a `where T: Compare` (or `Add`, `Div`) bound: `hasDerive` gives
  `false` for every `TyVar`. Inside a generic body only stringification, and
  operands the checker leaves untyped (a field of a generic record read
  through `T`), reach the unsigned positions.
- A member read on a value of type `T` is accepted untyped, so a "duck-typed"
  generic can reach a `UInt` field of a record type argument. Mono does not
  report such a specialisation for a re-check, because its type arguments do
  not mention `UInt`/`ULong`.
- A stdlib or other-package generic specialised with signed type arguments
  is not re-checked. A concrete `UInt` operand in its body therefore depends
  on its own spelling.
