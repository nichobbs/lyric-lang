# `lyric prove` divides signed integers the way the program does (#7870)

Lyric's signed `/` and `%` truncate toward zero on every target: `-7 / 2`
is `-3`, `-7 % 2` is `-1`, and the remainder takes the dividend's sign.
`Lyric.Verifier` rendered them on `Int`, `Long` and `Nat` as SMT-LIB's
integer `div` and `mod`, which are Euclidean — the remainder is never
negative, so `(div (- 7) 2)` is `-4` and `(mod (- 7) 2)` is `1`. Whenever
the dividend was negative and the division inexact, the proof reasoned
about a different value from the one the program computes:

- `ensures: result == -3` on `x / 2` with `x == -7` was refuted, and
  `ensures: result == -4` was discharged;
- `ensures: result <= 0` on `a % b` with `a < 0` was refuted, and so was
  `y /= 4` yielding `-2` from `-9`: correct contracts could not be proved,
  while the Euclidean reading proved contracts the program violates.

A positive dividend over a negative divisor happened to agree (`7 / -2` is
`-3` both ways), which is why the existing examples never exposed it.

## Fix

- The SMT preamble defines truncating division and remainder once:

  ```
  (define-fun lyric!tdiv ((a Int) (b Int)) Int
    (ite (= b 0) (div a 0)
      (ite (= (>= a 0) (>= b 0)) (div (abs a) (abs b)) (- (div (abs a) (abs b))))))
  (define-fun lyric!trem ((a Int) (b Int)) Int
    (ite (= b 0) (mod a 0) (- a (* b (lyric!tdiv a b)))))
  ```

  and `smtRenderTerm` renders a signed-integer `BOpDiv`/`BOpMod` as a call
  to them. Defining them once keeps nested divisions linear in size, and
  the `!` in the names is a character `smtSanitize` never emits, so no user
  symbol can collide. Every operator the verifier emits goes through this
  one rendering, so contract clauses, bodies, compound assignments (`/=`,
  `%=`) and loop goals all change together.
- Division by zero keeps its previous meaning: nothing is known about it.
  The zero-divisor branch delegates to the solver's own `div`/`mod`, which
  SMT-LIB leaves unspecified per dividend, exactly as the plain rendering
  did. (Nothing in the verifier folds `/` or `%` on constants, and the
  trivial discharger works syntactically, so neither needed a change.)
- Unsigned `bvudiv`/`bvurem` and real `/` are unchanged.
- Review follow-ups from #7877: the unsigned-suffix width now has one
  helper, `unsignedSuffixWidth` in `theory.l`, used by `foldIntLiteral`
  and `translateLit` alike (it replaces `isUnsignedIntSuffix`), and a test
  covers a signed variable or expression passed at an unsigned parameter,
  which fails closed with `V0033`.

## Verification

`verifier_self_test.l` gains a rendering test (`(lyric!tdiv a b)`,
`(lyric!trem a b)`, the preamble definitions, real `/` untouched, and a
proved goal's SMT using `lyric!tdiv` rather than `div`) and z3-backed
cases that discharge the truncating result and refute the Euclidean or
floored one for `-7 / 2`, `7 / -2`, `-7 / -2` and the same three `%`
operand pairs, plus symbolic cases: a negative dividend's remainder is
non-positive, `a % b == a - b * (a / b)`, negating the dividend negates
the quotient, and a compound `/=`. `examples/unsigned_proof.l` adds two
signed-division obligations, proved in the CI "Prove proof-only examples"
step. Every signed case was also run through a z3 wrapper that restores
the old `div`/`mod` rendering: every case whose answer depends on the
rounding direction fails there (a correct result refuted, or a wrong one
discharged) and passes with the fix, while the cases both readings agree
on (a positive dividend, the division identity, a zero remainder) pass
either way. cvc5 gives the same results as z3 on the new rendering.
