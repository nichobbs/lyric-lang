# An unsuffixed literal takes a `Byte`/`UInt`/`ULong` target's type (#7841)

`var x: UInt = 10u32; x %= 7` was **T0063** ("assigned value of type Int does
not match target of type UInt"). The literal `7` stayed an `Int`, and no
`Int` widens to `UInt`.

- **The bug.** The issue reported that a binding (`val y: UInt = 7`) and a
  plain operator (`x = x % 7`) already accepted the literal, and asked for
  compound assignment to match them. Only the operator did. Next to an
  operand of another integer type a literal takes that type
  (`adoptIntLiteralType`, #2514). `inferExprExpected` gave a `Float`
  initialiser that treatment (D155), but never an integer one. So
  `val y: UInt = 7` was **T0060**, `x = 7` and `x %= 7` were **T0063**, and a
  `UInt` argument `g(7)` was **T0043**. For `Long` targets the `Int`
  literal widens implicitly, which hid the gap. `Byte`, `UInt` and `ULong`
  have no widening from `Int`, so they hit it.
- **The fix.** Where a `Byte`, `UInt` or `ULong` is expected, an unsuffixed
  integer literal whose value fits takes that type
  (`adoptUnsignedIntLiteral`). These are the positions:
  - `inferExprExpected`, which covers bindings, plain and compound
    assignments, return values, list and slice elements, and lambda results;
  - `literalArgSatisfiesParam`, which covers call arguments, constructor
    fields and collection-member arguments.

  The checker records the literal in the `argConversionSites` channel under
  `intLiteralSiteMethod(U8|U32|U64)`. `Lyric.Mono.desugarCheckedFile` then
  gives the literal its `u8`/`u32`/`u64` suffix, so every backend sizes the
  constant by the type it initialises: a `ULong` target gets a 64-bit
  constant, not an `Int` one.
- **Out of range.** A literal the target cannot hold keeps its own type. An
  assignment or compound assignment then reports **T0015**, as a binding does
  (`x += -1` on a `UInt`: "literal -1 is out of range for type UInt"), and
  no T0063. An argument stays an ordinary mismatch.
- **Changed expectations.** Two `typechecker_self_test.l` cases asserted the
  old rejection. `List[Byte].add(0)` (#7969) and a lambda returning `5` where
  `() -> Byte` is expected (#7865) are now accepted. Each test now rejects a
  literal the type cannot hold instead (`256`, `300`).
- **Docs.** docs/01 §2.1 (integer literals), book chapter 2 (integer
  literals), and the appendix B T0015 row.
- **Tests.**
  - `typechecker_self_test.l`: every `op=` and plain `=` with an unsuffixed
    literal on `Byte`, `UInt`, `ULong`, `Int` and `Long` checks clean; the
    recorded suffix sites; T0015 without T0063 for `x += -1` on a `UInt` and
    `x = 256` on a `Byte`; annotated bindings; a `UInt` argument.
  - `unsigned_typed_ops_self_test.l`, dotnet and JVM: runtime values of every
    `op=` on `UInt` and `ULong` locals and fields, with values at and above
    2^31 and 2^63, on `Byte`, and on `Int`/`Long` controls.
  - `byte_native_self_test.l`, native: the same for `Byte`, which is the only
    one of the three types native lowers.
