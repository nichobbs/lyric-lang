# Verifier: distinct values never share a term (#8109)

`lyric prove` gave two values the program can tell apart the same SMT
term in four places, so it proved claims a run violates. Each is now a
value of its own, or keeps its precision where the identity is real.

- **Calls of functions that are not `@pure`.** A free or static call of a
  function the file declares was the callee applied to its arguments, so
  `tick(x) == tick(x)` was proved for a counter. `translateResolvedCall`
  now applies the callee only when it is `@pure`; any other call's result
  is a fresh value at its call site (`callResultTerm`), with the callee's
  `ensures:` still assumed about it. This is the mechanism method calls
  got in #8101, now used by every resolved call. A callee the file does
  not declare (another file's, another package's, the standard library's)
  was keyed by name and arguments; `lyric prove` does not read other
  packages' contract metadata, so its purity is unknown and its result is
  fresh too. A `@pure` body the verifier cannot translate faithfully (V0033,
  or a value not of the result's sort) used to fail every goal that
  called it; it is now simply not assumed, and the call keeps its
  congruence and contract.
- **Function-valued bindings.** A function the file declares, named as a
  value, is one symbol per function (`fn!<name>`, sort `Function`). A call
  through a binding that holds one is a call of that function as the
  binding holds it at the call, so `var h = one; h(1)` and, after
  `h = two`, `h(1)` are `one(1)` and `two(1)`. Anything else a binding
  holds is a computed callee with a fresh result. A function bound by a
  destructuring pattern used to be called by its name, so two patterns
  binding `h` to different functions gave `h(1)` one term.
- **Unbound names and destructuring.** `val (a, b) = p` bound the value to
  a shared `?pat` and left `a` and `b` unbound, so each became a variable
  named after its identifier, and `a` from two patterns was one value.
  Each name a destructuring pattern binds is now a fresh `!`-named unknown.
  A name no binding declares is module-level (a `val`, which never
  changes) and is the symbol `global!<name>`, apart from a parameter or
  binding spelt the same; an assignment to such a name fails closed
  (V0026).
- **Locals leaking out of `if` branches.** `wpIfStmt` walks each branch
  followed by the rest of the block, so `val t` declared in a branch
  shadowed the outer `t` for the rest of the function. Branches, and
  function, lambda and loop bodies, are now scopes (`envEnterScope`,
  `envDeclare`, `envExitScope`): the first declaration of a name in a
  scope saves the binding it shadows, with its mutability, and a marker
  statement at the branch's end restores it. A postcondition placeholder
  for an `out`/`inout` parameter or a loop-changed variable reads the
  saved binding while the variable is shadowed.

Each refuted case was confirmed against a run: `tick(1) == tick(1)` and
the same through `val h = tick` are `false`; two destructured functions
`inc`/`triple` called through `h` differ; two destructured `a`s from
`(1, 0)` and `(2, 0)` differ; and the branch-shadowing function returns
the outer `t`, `5`, where the old encoding proved `7`.

`examples/rbac/src/policy.l`'s `dominanceTransitive` relied on two calls
of the unannotated `roleLevel` being equal. `roleLevel` is pure, so it is
now marked `@pure`. Its enum-`match` body is not translatable, which no
longer fails its callers, so the example now proves 11 of 13 obligations
(10 before): `noEscalation` no longer fails on `hasPermission`'s body, and
`adminHoldsAll` and `guestIsRestricted` still fail, as before, on the
enum matches the verifier does not model.

Not changed, and tracked in #8110: a call of a method the verifier does
not model is still an uninterpreted function of its receiver and
arguments, so `xs.count` before and after `xs.add(1)` is one term — the
verifier has no heap model of mutation through a receiver.

Verified by eleven new `verifier_self_test.l` tests (refuted and
discharged cases for each item and for each review finding), the
verifier and records self-tests, the
CI `lyric prove` examples, `core_proof.l`, `scripts/ci/prove-package-scope.sh`
and the compiler self-test batch.

## Review follow-up

The review found the congruence still unsound where the arguments do not
determine what a `@pure` callee reads, and the untranslatable-body change
had made it reachable: `app(l, 1)` with `l` a closure over a `var` that
changes between the calls, `call0(monotonicNanos)`, `probe(xs)` before and
after `xs.add(1)`, and a `@pure` read of a protected object were all
proved equal, and differ at runtime.

- `@pure` is trusted, and now congruent only when every argument is a
  value `==` sees all of (`allValueDetermined`): a primitive, `String`,
  `Unit`, a tuple or standard `Result`/`Option` of such values, an enum
  the file declares, a non-generic record or union whose fields are all
  immutable and of such types (`fileValueTypes`, held in
  `VEnv.valueTypes`), or a `@pure` function of the file named as a value.
  A closure, a function from elsewhere, a `List`/`Map`/`Set`, a slice, a
  protected or opaque object, a record with a `var` field, or an
  unmodelled value gives the call a result of its own.
- A call site's own result (`callSiteResult`) is now an uninterpreted
  function of its own applied to the arguments, not a constant, so under
  a quantifier it varies with the bound variable: `exists i. tick(i) ==
  i + 1` is no longer proved by taking `i` from one fixed result. The
  same holds for undeclared and computed callees.
- `==` and `!=` between function values fail closed (V0033): a .NET
  delegate compares its method and target and a JVM lambda its
  reference, so `val h = one; val k = one; h == k` is true on one target
  and false on the other.

A second review found two more:

- The built-in tuple sort was named `Tuple`, so a user `record Tuple {
  xs: List[Int] }` was taken for a value and a `@pure` call over it was
  congruent across `t.xs.add(1)`. The built-in sorts are now
  `Lyric!Unit` and `Lyric!Tuple<n>` (one per arity, now declared to the
  solver, which a tuple-sorted goal previously was not), and a file
  that declares or imports by name a type spelt like a primitive fails
  closed (V0033). The sorts of a record's fields (`xs: List[Int]`) are
  now declared to the solver too; a goal over such a record used to be
  a malformed query (V0007). `examples/ledger/src/accounting.l` now
  proves 7 of 7 obligations (4 before): `makeDebit`, `makeCredit` and
  `balancePreservation` failed only on the undeclared `AccountKind`
  field sort.
- Function-value equality was refused only for a top-level function or
  lambda. It is now refused for any operand that may hold a function:
  through `Option`/`Result`, tuples, records, unions, opaque types and
  aliases, and for values of unknown type — an imported name used as a
  value (`val h = monotonicNanos; h == k`), an unannotated lambda
  parameter. A module-level `val`/`const` with a declared type now has
  that type instead of an unknown one.

A third review found `==` modelled as structural where it is identity at
runtime: `Cell(v = 1) == Cell(v = 1)` for a record with a `var` field
(D164 item 2), directly or inside a union payload, was proved. And `==`
on a generic parameter `T` was taken as safe, so `same(one, one)` with
`requires: a == b` was proved though it fails on the JVM. `==`/`!=` are
now modelled only over a whitelist (`equalityModelled`): primitives,
`String`, `Unit`, tuples and standard `Result`/`Option` of such values,
enums, and the file's non-generic unions and records that compare field
by field (no `var` field, or `@derive(Equals)`) over such values, as a
greatest fixed point so a recursive record qualifies. Everything else —
mutable records, protected, opaque, interface and extern types, host
collections, generic records, functions, and values of unknown type —
fails closed (V0033). Inside a generic, `==` over its own type parameter
stays an opaque equivalence (so `core_proof.l`'s `identity[T]`
contracts still prove); where a call instantiates the generic's
contract, each `==` in it is checked again over the argument terms
(`checkInstantiated`), so `same(one, one)` fails closed. A union case
built with `U.C(args)` was an unmodelled method call, a function of its
arguments, so two `U.A(c = Cell(v = 1))` were one value; it is now a value
of `U`, congruent in its arguments only when `U` compares by structure
over modelled payloads. `scripts/ci/prove-package-scope.sh` accepts the
equality V0033 as well as the field-read one as evidence that a
sibling's `Option` is not modelled as the standard library's.

Specification: `docs/15-phase-4-proof-plan.md` §5.2, §5.4.
