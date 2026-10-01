# Unary minus on an unsigned operand is T0147; an unknown numeric suffix is L0015 (#7854)

Two front-end holes around integer literals, both found while fixing #7847.

## Unary minus on `Byte`, `UInt` and `ULong`

`inferPrefix` accepted `-e` for any numeric operand and typed the result as
the operand's type, so `-(5u8)` was a `Byte` and, on both targets, wrapped to
251; `-u` for a `UInt` or `ULong` wrapped the same way. No non-zero unsigned
value has a negation of its own type, so the operation has no meaning there.

- `-e` on an operand that is `Byte`, `UInt` or `ULong`, or a range over one
  (`UInt range 0 ..= 10`), is now **T0147**. The message names the operand
  type. For a `Byte` the hint is the explicit conversion `-(x.toInt())`.
  `UInt` and `ULong` have no conversion to a signed type yet (docs/01 §4.1),
  so their hint says to give a value that can be negative a signed type,
  rather than suggest a method that does not exist. The negation types as
  `TyError`, so a rejected `-b` does not cascade into a return-type mismatch.
- Distinct types were already rejected (`T0036`: no distinct type has unary
  minus, whatever its base). That stays, and is now pinned by a test.
- Range bounds are folded, not type-checked, so the checker's rule did not
  reach them: `type Small = Int range -(1u8) ..= 5` folded the bound to -1
  and was accepted. `tryFoldInt` now returns the new
  `FEUnsignedNegation` error for a negation whose operand is an
  unsigned-suffixed literal, a constant declared unsigned (or, unannotated,
  initialised by one), or arithmetic with such an operand. `foldOrErr`
  reports it as T0147 where the negation is written. A bound that reaches
  one only through another constant's initialiser
  (`val K = -(5u8)`, `type Small = Int range K ..= 5`) gets T0147 once, at
  the initialiser, plus `T0093` at the bound. An inline range type's bounds
  (`val n: Int range -(2u8) ..= 5`) are checked the same way when the type
  is resolved, and `exprLiteralLong` no longer folds a negated unsigned
  literal into a bound or a T0015 check.
- `Lyric.Pipeline.foldNegatedIntLiteral` and the verifier's `foldIntLiteral`
  already refused to fold an unsigned literal under a minus. The verifier
  still reports `V0033` for unsigned negation (#7848), because `lyric prove`
  does not run the type checker. It stays consistent with T0147: both reject
  the construct.

## L0015

docs/01 described `L0015` for an unrecognised numeric suffix, but the lexer
had no path to it. A decimal literal's tail was glued back onto its digits,
so `100xyz` failed the digit parse and reported the misleading `L0010`
("out of range"). A float with a bad tail (`1.5xyz`) reported `L0011`.

The suffix is now the whole run of ASCII letters, digits and underscores
that starts with a letter right after the digits. It must be exactly one of
the valid suffixes, or it is `L0015`. The message names the suffix and lists
the valid ones for that kind of literal, and its span covers the suffix:

- A decimal literal takes `i8` `i16` `i32` `i64` `u8` `u16` `u32` `u64`
  `f32` `f64`.
- A hexadecimal, octal or binary literal takes only the integer suffixes.
- A float literal takes only `f32` and `f64`.

The literal keeps its digits' value with no suffix, and no second `L0010` is
reported for the same typo. Because the suffix is one run, `1u8_x` is one
token with a bad suffix rather than `1u8` glued to an identifier. Existing
lexing is unchanged:

- Hex digits run first (`0xFFu8`, `0x1f32`).
- `.` starts a fraction only before a digit (`1..5`, `1.toString()`,
  `5u8.toInt()`).
- A malformed exponent (`1e`, `2em`) is still the one `L0011`.
- A decimal digit outside a binary or octal base (`0b12`) still fails the
  digit parse.

## Verification

New `typechecker_self_test.l` cases cover:

- `-b`, `-(5u8)`, `-5u8` and `-((b))` on a `Byte`.
- `UInt` cases, including `u16` and `-(u + 1u32)`.
- `ULong` cases, including the full-width `u64` literal.
- Inline unsigned range operands.
- A distinct `UInt range` type.
- Module-level `val -(5u8)` and `-B`.
- Named range bounds `-(1u8)`, `-B` and `-(B * 2u32)`.
- Inline local and parameter range bounds.
- The reported-once-through-a-constant case.
- A clean signed case: `-(b.toInt())`, `-l`, `-d`, `-(5i8)` and
  `-2147483648`.

New `lexer_self_test.l` cases cover:

- `100xyz`, `1u7`, `2i128`, `5u`, `5U8`, `1u8_x` and `1xi32`.
- `0xFFg`, `0b101z`, `0o17q` and `0b1f32`.
- `1.5xyz`, `1.5i32` and `1e5u8`.
- The one-`L0011` exponent cases.
- Every valid suffix in every base.
- The range and member forms.

Before the fix, 5 type-checker and 3 lexer cases failed; after it, the
lexer (77), type-checker (754) and parser (152) self-tests pass. The full
validation passed too: stage 2, the CI self-test matrix, the compiler, JVM
generics, ilverify and multi-package batches, and the 26-library ecosystem
matrix.
