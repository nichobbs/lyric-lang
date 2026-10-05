# Verifier: a quantifier ranges over its bound variable's type (#8214)

`lyric prove` translated `forall (x: T)` and `exists (x: T)` with `x` at
`T`'s sort and nothing more, so a range subtype's bound was lost:
`exists (i: Small) i == 70` was discharged for `type Small = Int range 0
..= 10`, and a `forall` over `Small` was checked against every integer.
`--explain` showed the bound variable as `exists(i: Int)`.

- **Quantifier domains.** `translateQuantifier` (`verifier/vcgen.l`)
  translates both quantifiers. Each bound variable gets the facts a
  parameter of its type gets: `forall x. facts(x) and where implies body`,
  `exists x. facts(x) and where and body`. The facts come from one new
  function, `valueFactsForTerm` (`verifier/theory.l`): the type's range
  and, for an `Int`/`Long`, its width. Parameters, havocked variables
  (loops, `out`/`inout` arguments, lambda captures), lambda parameters,
  uninitialized `var`s, callee results, record field reads and protected
  fields now all take their facts from it too, so a quantifier's domain
  and a parameter's facts cannot drift. The only new fact outside
  quantifiers is the width of an uninitialized `var`, whose range it
  already had.
- **Bound variable names.** Each bound variable is a solver name of its
  own (`i!0`). Before, it was the source name, so a term the body read
  from an enclosing binding spelt the same was captured:
  `exists (n: Small) old(n) == n` was the tautology `exists n. n == n`,
  proved even with `requires: n == 50`.
- **Type aliases.** A non-generic `alias` of a scalar (a primitive, an
  inline range, a distinct or range subtype, or another such alias) is
  registered with the file's distinct types. A value declared with
  `alias S = Small` is a `Small` in the proof. Before, it was an
  uninterpreted sort named `S`. Aliases of records, unions and other
  named types are unchanged.
- **`Char`.** A `Char` value was an uninterpreted sort, while a `Char`
  literal was its code point, so `c == 'a'` mixed sorts. A `Char` is now
  its code point, with the BMP-scalar facts `0 <= c <= 65535` and
  `c < 55296 or 57343 < c` (new `RBKBmpScalar` range kind).
  `exists (c: Char)` cannot be witnessed by a surrogate.

`UInt`, `ULong` and `Byte` bound variables are bitvectors and already
non-negative. A range subtype over a distinct type, a range subtype or
`Char` is `T0091` in the type checker, so no value needs two declared
ranges intersected.

Checked and left alone:

- A match binding of a supported pattern is the scrutinee's own term,
  with its facts.
- A destructuring binding, or a binding of an unsupported pattern, is
  an unknown of an uninterpreted sort, with no type to take facts from.
- `old(p)` is the parameter's own term.
- `for` loops are not modelled (V0026).
- A callee's `out`/`inout` post-value (`p!post`) is not linked to the
  caller's variable, which is havocked with its facts.
- A call to an undeclared function has an uninterpreted result.

One gap remains, tracked separately: a quantifier body's side conditions
and assumed facts are dropped. Lifting the assumed facts would be unsound
for a call site's fresh result, which does not vary with the bound
variable.

Tests in `verifier_self_test.l`, five new cases:

- **Range subtypes.** Refuted: `exists (i: Small) i == 70`,
  `forall (i: Small) i <= 5`, a `where` form, nested quantifiers past the
  range. Discharged: `forall (i: Small) i <= 10`, an in-range `exists`,
  and `Long` bounds.
- **Unsigned.** `UInt`/`ULong`/`Byte` range subtypes and plain `Byte`.
- **Distinct types and aliases.** Distinct-over-range and its chains,
  alias chains, inline ranges, and the width of a distinct `Int`.
- **`Char`.** The `Char` cases.
- **Capture.** The bound-variable capture case.

`lyric run` confirms the refuted claims:

- `Small.from(70)` panics and `Small.tryFrom(70)` is an `Err`, so no
  `Small` is 70.
- `Small.from(7)` holds 7, which exceeds 5.
- `Score.from(Small.from(11))` panics.
- `55296.toChar()` panics.

Verified:

- `verifier_self_test.l`: 167/167.
- `verifier_records_self_test.l`.
- The four CI prove examples: pagination 6/6, prove_demo 12/12,
  token_bucket_proof 7/7, unsigned_proof 18/18.
- `core_proof.l` 9/9.
- `prove-package-scope.sh`.
- The compiler self-test batch.
- Example projects, unchanged: rbac 11/13, ledger 7/7,
  product-catalog 6/12, jobqueue 4/5.
