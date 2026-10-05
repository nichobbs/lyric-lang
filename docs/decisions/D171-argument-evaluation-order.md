# D171 — Call arguments are evaluated left to right as written

**Status:** accepted, implemented (#8158)

## Context

docs/01 said how named and positional arguments pair with parameters, but
not in which order they are evaluated. Everywhere else the language promises
source order: `.copy(...)` evaluates "each argument exactly once, left to
right as written" (§2.4), and the `?` and `await` operand hoists preserve
left-to-right evaluation. Every backend, however, evaluated a call's
arguments in **parameter** order, so `two(b = pos(x), a = zero(x))`, with
`zero(x: inout Int)` setting `x = 0` and `pos` requiring `x > 0`, ran
`zero(x)` first and `pos` raised `PreconditionViolated`. The record
constructor `Pair(b = pos(x), a = zero(x))` did the same.

## Decision

1. **Source order.** A call evaluates its receiver first (a method call's
   `o` in `o.m(...)`), then each argument exactly once, left to right as
   written, positional and named alike, then the defaults of the parameters
   it leaves out. The values are passed in parameter order. This applies to
   every callee: free, generic, record-body, `impl`, interface, dot-named and
   protected-type callees, callees in restored packages, and record,
   exposed-record, opaque, protected-type and union-case constructors.

2. **Defaults run after the explicit arguments.** A default cannot read the
   caller's locals, so its order among the other defaults is only
   observable through a side effect of its own; the defaults of one call run
   in parameter order.

3. **Implemented once, in the middle end.** The type checker, which knows the
   callee's parameters, records each call whose explicit arguments would run
   observably differently in parameter order
   (`Lyric.Parser.callArgsNeedSourceOrder`): two arguments, or an argument
   and an omitted parameter's default, that each may cause or observe an
   effect meet in the other order. `Lyric.Mono.desugarCheckedFile` rewrites
   such a call, right after the check, into a block that evaluates those
   arguments (and a computed receiver) into fresh locals in source order and
   then makes the call with the same argument names and positions:

   ```
   o.m(b = eb, a = ea)   =>   { val r = o; val t0 = eb; val t1 = ea; r.m(b = t0, a = t1) }
   ```

   Every backend therefore inherits the order, and a call written in
   parameter order, or whose reordered arguments are inert (literals,
   negated literals, lambdas, names of immutable bindings), is unchanged.
   A temporary whose type is a generic instantiation is annotated with it,
   as the `?`/`await` hoists annotate theirs (#7823). The place an `out` or
   `inout` argument names, and a receiver that is a place, are never copied
   into a temporary; they denote the place itself.

4. **Contract clauses are exempt.** A call in `requires:` / `ensures:` /
   `invariant:` may only call `@pure` functions (T0133), whose evaluation
   order is unobservable.

## Consequences

- No new syntax or diagnostics. docs/01 §5.1 states the rule beside the
  argument-pairing rules.
- The backends' own argument pairing was corrected where it disagreed with
  the checker's (`Lyric.Parser.pairCallArgs`: named arguments by name, then
  positional ones into the free parameters left to right): native free,
  generic and interface-method calls and JVM constructors placed a
  positional argument written after a named one at its written position;
  the MSIL backend built a non-generic union case's named fields in written
  order and passed a stdlib function's named arguments in written order;
  native calls could not leave out a defaulted parameter that a later
  parameter follows. An `exposed record` is lowered natively as the record it
  is.
- The verifier's call rule (`lyric prove`) is brought in line with this
  decision separately (#8107); it must model the arguments in source order.
- Calls written type-qualified (`T.m(x, args)`, `T.f(args)`) are not resolved
  by the type checker today, so they are neither type-checked nor reordered;
  that gap is separate from this decision.
