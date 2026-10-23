# Contract and range soundness batch (#7900, #7901, #8145, #8226, #8331, #7410, #7529, #7436)

See D206 for the decisions.

- **Range bounds fit the base type** (T0182, #7900): `typechecker_resolver.l`
  `checkRangeBoundsFitBase`, called for inline refinements and named subtypes.
- **`-n` on a `Nat` is T0147** and a `UInt` converts to `Long`/`Double`/`Float`
  by value (#7901): the checker records a `toULong` widening on the receiver, so
  all backends zero-extend.  `ULong.toLong()/toDouble()/toFloat()` are T0103.
- **Call arguments are range-checked against the parameter's instantiation**
  (#8145): a case constructor, generic record or tuple passed straight as an
  argument notes its range slots whether or not it widens.
- **Definite assignment for range-typed variables** (T0183, #8226):
  `typechecker_definite.l`.
- **Interface method contracts are type-checked** (#8331):
  `checkInterfaceContracts`.
- **`@pure` on interface method signatures** (#7410): `FunctionSig.annotations`,
  carried by the parser, formatter, alias passes, mono, contract metadata; T0184
  for an impure implementation.
- **Protected `func` members re-check the invariant** (#7529): the contract
  elaborator passes the type invariants to `PMFunc` members.
- **Config parse failures exit 78 with G0003** (#7436) on dotnet (try region
  around the parse, `Bool` by hand) and the JVM (`NumberFormatException`
  handler).

Tests: `typechecker_self_test.l`, `fmt_self_test.l`,
`range_refinement_self_test.l` and `scripts/ci/range-refinement-e2e.sh`,
`invariant_self_test.l`, `conv_methods_self_test.l`,
`config_block_missing_required_self_test.l`.
