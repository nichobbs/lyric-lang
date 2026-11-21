# examples/ledger: `rowToAccount` called `unwrapOr` as a method (docs/70 phase 3a)

`examples/ledger/src/accounts.l` read `accountKindFromString(..).unwrapOr(AccountKind.Asset)`.
`unwrapOr` is a function of `Std.Core` (`unwrapOr(o, default)`), not a method of `Option`; the
checker accepted the method form without recording a type, and a build of the program fails at
run time with "unsupported method 'unwrapOr'" the first time `rowToAccount` runs (no test reached
it). The TIR gate (D347, I0002) reports exactly this body, so the example now calls the function.

The body builds under `--verify-ir` and `lyric test --manifest examples/ledger/lyric.toml`
passes (19 tests, both packages).
