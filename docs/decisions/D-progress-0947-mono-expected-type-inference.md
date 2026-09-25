# D-progress-947 — Monomorphizer: infer type arguments from the expected type

**Status:** shipped

## Problem

`Lyric.Mono` inferred a generic call's type arguments only from its
arguments. A type parameter that appears only in the return type could
therefore never be inferred:

```lyric
pub func stay[M, E](m: in M): Step[M, E]      // E appears only in the result
pub func heading[Msg](level: in Int, s: in String): View[Msg]

val s: Step[Model, Effect] = stay(m)          // M0002: could not infer 'E'
return heading(1, "Customers")                // M0002 / M0004
acc.add(heading(2, "Details"))                // M0004
```

The type checker accepted all three, since it does use the binding
annotation, the return type and the parameter type. The monomorphizer,
which runs after it, did not, so the program failed to build. The only
workaround was explicit type application at every call site, which a
combinator-style API makes pervasive. Generic *record* constructors had the
same gap in the type checker itself: `val b: Box[Int, String] = Box(left =
xs, right = None)` reported T0110, although union-case constructors already
took their type arguments from the expected type.

## Decision

- **Expected types in `Lyric.Mono`.** Before a position is rewritten, the
  type it expects is recorded against the spans of the calls in its tail
  positions (through parentheses, `if`/`match` arms and block tails) in
  `MonoState.expectedAt`:
  - an annotated `val`/`var`/`let` initialiser;
  - a `return` value, or a function body's trailing expression, against the
    enclosing function's declared return type (`rewriteFuncBodyWithRet`;
    lambdas mask it, since their result type is not known here);
  - an assignment to a variable whose type is known;
  - an argument to a non-generic callee's parameter of known type;
  - the argument of `list.add(x)` when `list`'s element type is known.
- **Keys.** A position is keyed by the origin package of the body being
  rewritten plus the call's span offsets. The origin matters because a
  specialised copy of an imported generic carries spans from that package's
  source, which can equal offsets in this file. A synthesized, zero-width
  span is never keyed, since it does not identify one call.
- **Use.** When argument inference leaves a type parameter unbound, the
  generic's declared return type is unified with the call's expected type
  before the imported-generic `Object` fallback and the M0002/M0004
  diagnostics.
- **Specialised signatures join the inference surface.** Each specialised
  copy is registered in `funcDecls`, and an unannotated `val` whose
  initialiser was just rewritten is typed from the rewritten call, so
  `val v = f(...)` gives `v` a concrete type for later generic calls.
- **Qualified type heads unify.** A declaring package spells its own type
  bare (`Node[M]`) while a consumer may qualify it (`Pkg.Node[Msg]`, or the
  full path once an alias is expanded). `unifyTE` used to require identical
  head paths, so such a call bound nothing and fell back to `Object`,
  producing a specialised copy over `Node<object>` and an invalid cast at
  run time. Heads now match when the shorter path is a segment-wise suffix of
  the longer (`typeHeadsMatchMono`); unification only sees calls the type
  checker has accepted, so matching trailing segments name the same type.
- **Record constructors (type checker).** `inferConstructionExpected` fills
  a generic record constructor's unbound type parameters from an expected
  instantiation of the same record; `inferExprExpected` routes an annotated
  binding's constructor initialiser through it.

## Verification

`typechecker_self_test.l` covers the record-constructor case. The
cross-package repro project covers a return-type-only type parameter
inferred from a binding annotation, a function's return type, a parameter
type and a `List` element type.
