# Release contract policy for impl, record and protected-type methods (#8680, D307)

`Lyric.ContractElaborator` applied the release policy (D297) to free functions
only. `elaborateRecordDecl`, `elaborateImplDecl` (through
`elaborateFunctionWith`) and `elaborateProtectedMember` now take the release
flag and elaborate each member from a view without the elided clauses, then
restore the source-level clauses, as `elaborateItem` does for a function.

- Record methods and protected entries/funcs: `ensures:` elided, `requires:`
  kept only when the type is `pub` (members take their type's visibility).
- `impl` methods: own and inherited `requires:` are kept (reached through the interface),
  every `ensures:` is elided.
- Protected-type `invariant:` clauses are always checked.

Tests: `scripts/ci/release-contracts-e2e.sh` gains a program per member kind
(debug and release, dotnet/jvm/native). Docs: language reference "Contracts in
`--release`", book chapter 17 section 17.4, D307.
