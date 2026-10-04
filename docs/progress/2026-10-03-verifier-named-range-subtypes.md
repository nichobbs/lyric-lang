# `lyric prove` uses named range subtypes' bounds (#7872)

`Lyric.Verifier` resolved a distinct type to its underlying type and never
read `DistinctTypeDecl.rangeClause`, so a value of a named range subtype
such as `type Port = UInt range 1 ..= 65535` brought no bound into a proof:
`func f(p: in Port): Bool ensures: result { p >= 1u32 }` went unproved.
Only inline `T range a ..= b` annotations carried one. Constructing a range
subtype carried no obligation either: `Port.from(x)` was an uninterpreted
call, and `p.value` an uninterpreted field.

Related gaps from #7877's review: an uninitialised range-typed `var` lost
its range, so a value assigned to it carried no bound, and the range
hypothesis of an initialised binding was stated over a free variable of the
binding's name rather than the value it is bound to, so it constrained
nothing.

## Fix

- A named range subtype stands for its refined underlying type in the
  verifier's distinct map (`type Port = UInt range 1 ..= 65535` is `UInt
  range 1 ..= 65535`), so every sort lookup through it — parameters,
  protected-type fields, results, bindings — gets the range, folded in the
  base sort with #7848's unsigned-aware bound folding; a bound it cannot
  state is `RBKUnsupported`. A range subtype of another range subtype
  resolves through the chain.
- `T.from(x)` and `T(x)` on a distinct type are the value `x` at the
  underlying sort; for a range subtype, `x` lying in the range is a side
  condition, and an unsupported bound is `V0033`. `x.value` on a distinct
  value is the identity. `T.tryFrom(x)` stays uninterpreted: it checks at
  runtime and returns an `Err`, so it carries no obligation.
- Record fields carry their sort info (`VEnv.fieldInfos`); a field read of a
  range subtype or of `Int`/`Long` assumes its bound and width.
- A callee's result carries its declared range as a hypothesis (the callee
  proves it).
- A binding's range hypothesis is stated over the bound value; an
  uninitialised `var` keeps its declared range, and each value assigned to a
  range-typed variable carries the bound (the runtime checks it after every
  assignment).
- A call whose callee is not a path (`x.f(y)`) keeps its arguments'
  obligations and facts instead of dropping them.

## Verification

`verifier_self_test.l` discharges `p >= 1u32` and `p <= 65535u32` for a
`Port` parameter and refutes `p >= 2u32`, does the same for a signed `Age =
Int range 0 ..= 150` parameter and record field, discharges `Port.from(80u32)`
and `Age.from(42)` and refutes `Port.from(0u32)`, `Age.from(151)` and an
unconstrained `Port.from(x)` (also through a `val`), discharges a bounded
`Port.from(x)`, `p.value`, a range-typed result passed through, a callee's
range-typed result, and a value assigned to an uninitialised range-typed
`var`.
