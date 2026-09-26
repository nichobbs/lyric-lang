# D-progress-984 — Integer literals are range-checked; mixed-width arithmetic widens on every backend

**Status:** shipped

Closes #7346 and #7350.

## #7346: unsuffixed integer literals

An unsuffixed integer literal was typed `Int` whatever its value, with no
diagnostic. `val y: Int = 2147483648` compiled on both targets:

- dotnet stored `-2147483648`;
- the JVM pushed a `long` into an `int` slot and failed verification.

`val n: Int = -2147483649` also wrapped silently.

Now:

- An unsuffixed literal is an `Int` when its value fits and a `Long`
  otherwise (`typeOfLiteral`).
- `-2147483648` stays an `Int`. It parses as a negated `2147483648`, so
  `inferExpr`'s negation arm recognises it (`unsuffixedIntLiteralValue`).
- A literal outside the range of the plain integer type a `val`/`var`/`let`
  declares is **T0015** ("literal N is out of range for type T"). Before
  this, T0015 covered only inline range refinements. The generic
  T0060/T0061/T0062 mismatch is not reported on top of it.
- Operator-operand adoption (`b == 200` with `b: Byte`) now requires the
  value to fit the adopted type. A `Long`-valued literal may adopt
  `UInt`/`ULong`.
- After type checking, the pipeline folds `-<unsuffixed literal>` into a
  single negative literal (`foldNegatedIntLiteral` at the end of
  `pipeCheckAndMono`). Each backend then sizes `-2147483648` by its real
  value instead of by its operand; several independent MSIL type-inference
  helpers had sized it as a `long`. The fold looks through parentheses, as
  the checker does, so `-(2147483648)` is folded too (#7397).

## #7350: mixed-width arithmetic

The checker's `widenArithmetic` (M6) types `Int op Long` as `Long`,
`UInt op ULong` as `ULong` and `Float op Double` as `Double`. The backends
did not widen:

- **MSIL** chose the opcode from the left operand only, so an `i4` and an
  `i8` were added as `int32` and the result silently truncated
  (`1 + 3000000000i64` printed `-1294967295`).
- **JVM** `+` did the same and failed verification. `- * / %` already
  widened `int`/`long` through `reconcileCmpOperands`, but sign-extended a
  `UInt` and ignored `Float`/`Double`.
- **Native** panicked on any mixed pair. It also let an integer literal
  "adapt" to the other side's width without checking the value fits.

Now:

- **MSIL:** `widenArithOperandsMsil` widens the `i4`-class operand
  (`conv.i8`, or the new `MConvU8` for a `UInt`) in `+ - * / %`, including
  the await-spill operand orders.
- **JVM:** `reconcileArithOperands` zero-extends a `UInt` via
  `Integer.toUnsignedLong`. `reconcileCmpOperands` widens `Float` to
  `Double` with `f2d`, which also fixes comparisons. `+` goes through the
  same path.
- **Ordering comparisons** (`<`, `<=`, `>`, `>=`, #7382). A first draft
  widened only arithmetic. MSIL's relational arms combined an `i4` with an
  `i8` unconverted: unverifiable IL that the JIT happened to sign-extend.
  The JVM sign-extended a `UInt` beside a `ULong`, so
  `4000000000u32 < 5000000000u64` was false on both targets. MSIL's four
  relational arms now call `widenArithOperandsMsil`. On the JVM every
  comparison site goes through `reconcileWidenedOperands`, the unsigned-aware
  step `reconcileArithOperands` already used. `==`/`!=` still require
  identical types (T0032).
- **Native:** `widenOperands` sign-extends `Int`, zero-extends `Byte`, and
  lets a literal adapt only when it fits. It replaces `unifyOperands`.

## Specification

`docs/01-language-reference.md` and book chapter 2 said Lyric has "no
implicit numeric widening". The checker has admitted lossless widening
since M6: arithmetic and comparison operands, and arguments and bindings
through `argSatisfiesParam`. Both documents now describe that shipped rule
(`Byte < Int < Long`, `Byte < UInt < ULong`, `Float < Double`; never
narrowing, never across chains). If the intended language has no implicit
widening at all, the checker is what must change, and that needs a new
decision.

## Tests

- `int_literal_range_self_test.l` runs on dotnet, JVM and native.
- `mixed_width_arith_self_test.l` covers every operator in both operand
  orders, call results, a negative `Int`, `Float op Double` and compound
  assignment, on dotnet, JVM and native.
- `mixed_width_unsigned_self_test.l` covers every `UInt op ULong` operator
  and ordering comparison on dotnet and JVM; native has no unsigned types
  yet.
- `mixed_width_arith_self_test.l` also covers `Int`/`Long` and
  `Float`/`Double` ordering comparisons.
- `typechecker_self_test.l` adds three T0015 cases.
- The native runs are wired into `scripts/ci/native-target-smoke-test.sh`.
