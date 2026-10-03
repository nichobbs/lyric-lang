# `lyric prove` binds call arguments to parameters by name (#7873)

At a call, `Lyric.Verifier` checks the callee's `requires:` and assumes its
`ensures:` with each parameter replaced by its argument (the Hoare call
rule, docs/08 §10.4). It paired them by position, so `clamp(hi = 10, lo =
0, x = v)` bound `x` to `10` and `hi` to `v`: a correct call could be
refuted and an incorrect one proved. An omitted defaulted parameter had no
argument at all and stayed a free variable in the instantiated contract.
Record constructors had the same flaw in the constructed value: #7848 gave
each named argument its field's sort but kept the written order, so
`P(y = 1, x = 2)` built `P(1, 2)`, and an omitted defaulted field left the
constructor short of an argument.

## Fix

- `Lyric.Parser.pairCallArgs` pairs a call's arguments with a parameter
  list the way the type checker does (named arguments by name, positional
  ones into the free slots left to right) and returns `Err` with the reason
  when they cannot be paired. `argsWithDefaults`, which every backend uses,
  now calls it and keeps its internal-compiler-error report for a call the
  type checker should have rejected; `lyric prove` does not type-check
  first, so the verifier uses the non-panicking form.
- `pairArgTerms` builds a call's argument terms in parameter order: each
  argument at its parameter's sort, and an omitted parameter's default
  translated in the callee's parameter scope (an earlier parameter it names
  is replaced by that parameter's argument), its own side conditions joining
  the call's. The call's term, the parameter substitution for `requires:`,
  `ensures:` and a `@pure` body all use that order.
- A record constructor pairs its arguments with the record's fields the same
  way; `VEnv.recordDefaults` carries each record's field defaults.
- Arguments that cannot be paired (an unknown name, a parameter given twice,
  too many arguments, an omitted parameter with no default) are `V0033`, and
  every goal built from that call is failed (#7874).

## Verification

`verifier_self_test.l` discharges and refutes a callee postcondition through
reordered named arguments, a positional argument after a named one, a
`clamp` call whose named bounds meet or violate its precondition, an omitted
default (and the same parameter given by name), a precondition met by a
default, record constructors with reordered named fields and an omitted
defaulted field, and fails closed on an unknown parameter name and a
missing argument.
