# Private generic helpers travel with a pub generic on dotnet (#8427, D215)

- `Lyric.ContractElaborator.carryPrivateGenerics` finds the private generics a `pub` generic reaches (to a fixpoint,
  skipping names bound locally) and returns the `pub` generics with their calls rewritten plus the helpers renamed
  `__priv_<Pkg>_<name>`.
- `pipeAddGenericFuncs` (same-project packages) and `buildContractFromFile` (restored dependencies) use it, and the
  MSIL and JVM bridges re-attach the private generics `Lyric.Mono` strips so the contract builder sees them. A
  `--target dotnet` consumer of a built package, or of a sibling package in the project, now builds what native
  and the JVM already accepted.
- Tests: two `msil_project_bridge_self_test.l` cases (two libraries with a private `step` each, and a parameter that
  shadows a helper), one `contract_meta_self_test.l` case (carried names, `internal` visibility, unreached helpers
  left out), and a two-project dotnet and JVM run of a library with private generics.
- Private non-generic helpers are unchanged (T0123 on dotnet and the JVM). A restored generic function on the JVM is
  #8089.
