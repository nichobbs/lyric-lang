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
  callee results, record field reads and protected fields now all take
  their facts from it too, so a quantifier's domain and a parameter's
  facts cannot drift.
- **Bound variable names.** Each bound variable is a solver name of its
  own (`i!q!0`). Before, it was the source name, so a term the body read
  from an enclosing binding spelt the same was captured:
  `exists (n: Small) old(n) == n` was the tautology `exists n. n == n`,
  proved even with `requires: n == 50`. The type checker reads that
  `old(n)` as the bound variable while the verifier's entry snapshot is
  the parameter, so an `old(...)` operand that reads a name an enclosing
  quantifier binds now fails closed (V0033).
- **Type aliases.** A non-generic `alias` of a scalar (a primitive, an
  inline range, a distinct or range subtype, or another such alias) is
  registered with the file's distinct types. A value declared with
  `alias S = Small` is a `Small` in the proof. Before, it was an
  uninterpreted sort named `S`. Aliases of records, unions and other
  named types are unchanged.
- **Type parameters.** A function's type parameter named like a
  file-level distinct type or alias took that type's range:
  `func pigeon[Bit](a: in Bit, ...)` beside
  `alias Bit = Int range 0 ..= 1` proved a pigeonhole claim that fails
  with `String` arguments. The `type Bit = ...` form of this predates the
  change. Types are now resolved in the scope they are written in:
  - the function's type parameters shadow file-level types and
    primitives;
  - a callee's signature is resolved against the callee's type
    parameters, never the caller's;
  - a distinct type's or alias's right-hand side is resolved at module
    level.
- **`Char`.** A `Char` value was an uninterpreted sort, while a `Char`
  literal was its code point, so `c == 'a'` mixed sorts. A `Char` is now
  its code point, with `0 <= c <= 65535`, the UTF-16 code-unit range
  every target guarantees. It is not assumed to lie outside the surrogate
  range: a `Char` an extern returns (`System.Convert.ToChar(55296)`, JVM
  `Character.highSurrogate`) is not checked and can be one.
- **Primitives named in other files.** A type named like a primitive in
  another file of the package (`enum Char` in a sibling) was taken for
  the primitive. The sibling type names `lyric prove` already collects
  (#8108) now count, and a file whose siblings are not all known fails
  closed. Siblings are read the way the package build reads them. The
  build strips `package` and `import` lines and parses the concatenated
  bodies, so a file with no `package` line is part of the package. Such
  a file is parsed again under a `package` line and contributes its
  types; if it still does not parse, the siblings are unknown. A file
  that does not parse and whose `package` line names another package is
  skipped, because its body fails any build it is in. This keeps
  `examples/agent/*.l` (packages `Examples`, `Examples.Contracts`,
  `Examples.Di`, `Examples.Tests`, none of which parse) from making every
  CI prove example fail closed. Any other unparseable file makes the
  siblings unknown. The `Result`/`Option` guard (#8108) reads the same
  scope. Only a single-segment name is a primitive, so `Other.Char` is
  package `Other`'s type.
- **Uninitialized `var`s.** `var y: Int range 5 ..= 10` was assumed in
  its range, but read before any assignment it holds 0, so `y >= 5` was
  proved and fails at runtime. It now carries only its width.

`UInt`, `ULong` and `Byte` bound variables are bitvectors and already
non-negative. A range subtype over a distinct type, a range subtype or
`Char` is `T0091` in the type checker, so no value needs two declared
ranges intersected.

Checked and left alone:

- A match binding of a supported pattern is the scrutinee's own term,
  with its facts.
- A destructuring binding, or a binding of an unsupported pattern, is an
  unknown of an uninterpreted sort, with no type to take facts from.
- `old(p)` is the parameter's own term, except under a quantifier binding
  `p` (above).
- `for` loops are not modelled (V0026).
- A callee's `out`/`inout` post-value (`p!post`) is not linked to the
  caller's variable, which is havocked with its facts.
- A call to an undeclared function has an uninterpreted result.

One gap remains: a quantifier body's side conditions and assumed facts
are dropped. Lifting the assumed facts would be unsound for a call site's
fresh result, which does not vary with the bound variable.

Tests in `verifier_self_test.l`:

- **Range subtypes.** Refuted: `exists (i: Small) i == 70`,
  `forall (i: Small) i <= 5`, a `where` form, and nested quantifiers past
  the range. Discharged: `forall (i: Small) i <= 10`, an in-range
  `exists`, and `Long` bounds.
- **Unsigned.** `UInt`, `ULong` and `Byte` range subtypes, and plain
  `Byte`.
- **Distinct types and aliases.** Distinct-over-range types and their
  chains, alias chains, inline ranges, and the width of a distinct `Int`.
- **`Char`.** A code unit, which may be a surrogate.
- **`old()` under a binder of the same name.** V0033.
- **Type parameters named like file-level types.** The pigeonhole proof
  fails.
- **Sibling and qualified primitive names.** Unknown siblings fail
  closed, and a header-less sibling declaring `Char` or `Result` is
  read.
- **Uninitialized `var`s.** Refuted.

`verifier_records_self_test.l` now proves with an empty known scope (an
in-memory file is its package's only file).

`lyric run` confirms each refuted claim:

- `Small.from(70)` panics and `Small.tryFrom(70)` is an `Err`.
- `Small.from(7)` holds 7.
- `Score.from(Small.from(11))` panics.
- `pigeon("x", "y", "z")` and `notSurrogate(Convert.ToChar(55296))`
  violate their postconditions.
- An uninitialized `var y: Int range 5 ..= 10` makes `y >= 5` false.

Example projects are unchanged: rbac 11/13, ledger 7/7,
product-catalog 6/12, jobqueue 4/5.
