# Private non-generic helpers of a pub generic are copied with it (#8427, D230)

- `Lyric.ContractElaborator.carryPrivateGenerics` now also copies the private non-generic helpers a `pub` generic
  reaches (directly, through other helpers, from a lambda), under `__priv_<Pkg>_<name>`, when a copy is the same
  function (`plainCopyable`): no private module-level `val`/`const`, private type or private union/enum case, no
  contract clause or default argument, no annotation but `@pure`/`@io`, a name used by one function only. A name
  already starting `__priv_` (read back from a restored package) keeps it.
- `Lyric.Mono.isCarriedPlainMono`: a copy is specialised like a generic with no type parameters, once per package,
  as `<name>__copy`.
- Contract metadata records each copy `internal` with its body; the `Msil.Bridge` and `Jvm.Bridge` contract builders
  take the private helpers as written before the middle end (`Lyric.Pipeline.pipePrivatePlainFuncItems`). The JVM
  source-dependency collector (`collectStdlibGenericFuncsJvm`) copies them for every package but `Std.*`.
- Helpers that fail the test stay T0123 (message extended on both backends); making those work while keeping one
  instance of module state needs the export design D230 rejected for now, tracked in #8546.
- Tests: two `msil_project_bridge_self_test.l` cases (two libraries with a private `scale` each, a helper chain and a
  lambda; a parameter that shadows a helper), `contract_meta_self_test.l` (`testBuildCarriesPrivatePlainHelpers`:
  carried, left out, shadowed), and `scripts/ci/private-helper-carry-e2e.sh` (library built as a dependency, app
  tests on `--target dotnet` and `--target jvm`, and a negative check that a stateful helper stays T0123).
- Restored (JAR) generics cannot be called on the JVM (#8089); the JVM carry is covered for source dependencies.
