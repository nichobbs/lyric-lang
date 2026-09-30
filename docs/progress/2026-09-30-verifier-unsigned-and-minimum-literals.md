# `lyric prove` models unsigned integers and the signed minimum literals soundly (#7848, #7853)

`Lyric.Verifier` gave `UInt`, `ULong` and `Byte` a `(_ BitVec n)` sort but
translated everything around them as mathematical integers:

- `translateLit` emitted every integer literal as an `Int` (a wide `u64`
  literal as `v + 2^64`), so `x > 3000000000` with `x: UInt` compared a
  bitvector with an integer.
- The SMT emitter rendered `+`, `<`, `/`, `%` on bitvectors as the integer
  operators, which are ill-sorted there; the signed `bvs*` reading was never
  an option either, and the unsigned one never emitted.
- `theory.l`'s `foldExprToLong` folded range bounds signed, so a `u64`
  bound from 2^63 up (`..= 18446744073709551615u64`) became `-1`, and a
  bound that was not a literal was silently dropped — including from a
  function's result-range obligation.
- `Long.MinValue` (`-9223372036854775808`, `-0x8000_0000_0000_0000`) was a
  negation of a literal whose magnitude is carried as the negative pattern
  `Long.MinValue`; the SMT literal renderer negated it with `-n`, which
  overflows back to itself, and emitted `(- -9223372036854775808)`, a bare
  negative numeral SMT-LIB does not define (z3 happens to accept it, cvc5
  does not). `prettyTerm` printed `(--9223372036854775808)`.

Before this change an obligation mixing an unsigned variable with a literal
was ill-sorted, so the solver answered with an error and the goal was
`V0007`; nothing that depended on unsigned ordering, division or range
bounds could be proved or refuted.

## Fix

- `Lit.VLBitVec(bits, width)` is a bitvector constant. A `u8`/`u16`/`u32`/
  `u64` literal translates to one of its width; a wide `u64` literal's
  two's-complement pattern is its bit pattern, rendered as the unsigned
  decimal `(_ bv18446744073709551615 64)`.
- `Lyric.Verifier` reconciles integer/bitvector sorts (`theory.l` §6): an
  integer constant next to an unsigned operand becomes a bitvector of that
  operand's width (the type checker's "a literal takes its neighbour's
  type" rule), a narrower unsigned operand zero-extends along
  `Byte < UInt < ULong` (`BOpZeroExtend`), and a `Byte` enters the signed
  chain through `bv2nat` (`BOpBvToNat`). VC generation applies it to binary
  operators, `if` branches, `val`/`let`/`var` initialisers and assignments
  at their declared type, call arguments at their parameter's type, record
  constructor arguments at their field's type, and the returned value at
  the result type. The driver runs it once more over each goal, since
  substitution can bring a constant next to a bitvector after translation.
- The SMT emitter picks the bitvector operator by operand sort: `bvult`/
  `bvule`/`bvugt`/`bvuge`, `bvudiv`/`bvurem`, `bvadd`/`bvsub`/`bvmul`.
- Range bounds fold against their base sort: unsigned and held as a bit
  pattern for a bitvector base, signed for an integer base. A bound that
  does not fit (negative or too wide for an unsigned base, a wide `u64` on a
  signed base, or not a literal) is `RBKUnsupported`: it adds no
  hypothesis, and a result-range obligation that needs it is `V0033`
  instead of being dropped. A range over a distinct alias takes the alias's
  underlying sort.
- `@proof_required(checked_arithmetic)` now also proves that unsigned `+`,
  `-` and `*` do not wrap (`x <= x + y`, `y <= x`, `y == 0 or (x * y) / y ==
  x`, ordered unsigned).
- A minus applied directly to a signed or unsuffixed literal is one signed
  constant, as `Lyric.Pipeline.foldNegatedIntLiteral` does for the backends
  (`Lyric.Verifier.foldIntLiteral`); `Long.MinValue` renders as
  `(- 9223372036854775808)`.
- New error `V0033`: a construct with no faithful translation (an unsigned
  operand beside a signed variable, a negative or too-wide constant used as
  an unsigned value, an unsigned negation, an unsupported result-range
  bound). The goal is not handed to the trivial discharger or the solver.
- `parseModel` keeps a parenthesised sort such as `(_ BitVec 32)` whole in a
  counterexample binding.

## Verification

`verifier_self_test.l` gains rendering, reconciliation and z3-backed prove
cases that both discharge and refute obligations over `UInt`/`ULong`
literals at and above the sign bit, unsigned range subtypes, unsigned
division and remainder, zero-extension, checked unsigned arithmetic, the
V0033 fail-closed paths, and `-9223372036854775808`,
`-0x8000_0000_0000_0000`, `-2147483648i32` and `-128i8`. The new
`examples/unsigned_proof.l` joins the CI "Prove proof-only examples" step
(10/10 obligations discharge).
