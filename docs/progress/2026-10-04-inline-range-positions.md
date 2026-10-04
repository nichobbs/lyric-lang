# Inline range types are checked wherever a value reaches one (#8031)

An inline range type (`Int range 0 ..= 3`, not a named `type Slot = ...`) was
checked at runtime only on a function parameter, a return, a binding and a
`var` assignment (#7226). Elsewhere it accepted any value: `R(i = ten())`
stored 10 in an `i: Int range 0 ..= 3` field on every target. docs/01 promises
a range-constrained value is always in range, in every build (D163).

## Positions now checked

- **Record fields:** a record, exposed-record or union field at construction
  (named and positional arguments) and in `.copy(...)`.
- **Assignments:** to a `var` field or to an element. A compound assignment
  `r.f += 1` checks its result.
- **Elements:** list, array and tuple literal elements, and collection
  arguments (`xs.add(x)`, `m.add(k, v)`, `xs[i] = x`) whose element type is a
  range.
- **Function values:** an argument through a function value whose parameter
  is a range (`val f = { k: Int range 0 ..= 3 -> k }; f(x)`).
- **Instantiations:** an argument to a type parameter instantiated with a
  range, and a union case's payload where an instantiation with a range is
  expected (`val o: Option[Int range 0 ..= 3] = Some(x)`).

A failure names what it checked: `RangeViolated: Slot field i must be in Int
range 0 ..= 3`.

## Design

**Checker.** `TyRefined` now carries the refined type as written (`source`).
The checker records each value reaching a range type at these positions
(`noteRangeSlot`, `SymbolTable.rangeCheckSites`, keyed by the value's span) and
each compound assignment to a refined field or element (`rangeCompoundSites`).
Positions the elaborator already checks are not recorded.

**Pass.** `Lyric.ContractElaborator.insertRangeSiteChecks` runs in the shared
pipeline after the overflow pass. It wraps each recorded value in a call to a
checker synthesized for that site, `__lyric_range_<n>(v)`, which asserts the
range and returns `v`. A compound assignment becomes a plain one whose value
is checked: `r.f = __lyric_range_<n>(r.f + 1)`. An `Int` or `Long` bound
written as a name uses the value the checker folded, so the checker needs
nothing from the package that declared the range.

**Backends.** The JVM registers the synthesized checkers after the middle end,
as it does derive-synthesized functions. Native had no lowering for an inline
range type at all and failed the build; it now lowers one as its base type.

## Tests

- `range_refinement_self_test.l` (17, dotnet and JVM): fields (named bounds
  folded, `Long`, `Double`), `.copy`, field assignment and compound assignment,
  union payloads, a function value, list elements (added, assigned, literal),
  an `Option` and a `Map` instantiated with a range, a tuple element.
- `scripts/ci/range-refinement-e2e.sh` (10 cases, all three targets; native in
  the native lane): each panic with its exact message, after the in-range use
  before it.

Inline ranges are still not a bounds-check elision proof (D167): a value from
an `extern func` or a module-level `val` is not checked.
