# D615 - A protected type's field defaults and an executable's interface are carried to importers (docs/70 phase 3a, #8613)

**Status:** shipped; builder and interface producer, the checker is unchanged. Amends D327 item 8 (an executable embeds no interface).

## Context

A construction that leaves a field or parameter out takes its default, and the typed IR makes that default an explicit argument of the call (D482). A default declared in another package is read from that package's interface. Two kinds of call found none and counted their body unbuilt (I0002, "a default argument declared in another package"):

- `SessionRegistry()` and `RegistryCell()` in `Ui.Host.Web::router`: a protected type's fields declare initialisers (`var byId: Map[String, SessionEntry] = newMap()`), which are its fields' defaults. The producer wrote the defaults of functions, methods and records and never those of a protected type, and wrote a protected type as a field-less `IfDType`, although `IfDRecord`'s own description in the model reads "a record, exposed record or protected type".
- `Cli.ResolvedManifestDeps(...)` in the compiler's self-tests (eight sites): `Lyric.Cli` declares `main`, so by D327 item 8 it embeds no interface, and a package that imports it as a restored dependency has no defaults to read. The compiler's executable package is imported by its own self-tests.

## Decision

`buildPackageDefaults` builds the initialiser of every field of a non-generic protected type (`noteProtectedFieldDefaults`, as `noteFieldDefaults` does for a record), and the interface producer writes a protected type as `IfDRecord` with its fields (`fieldsOfProtected`: the field's type, whether it is mutable, and its default), as the model describes. A consumer reads the default as it reads a record field's, by the type's DefPath key.

An executable's interface is built and embedded too. A declaration the interface cannot record is T0223 for a library, because its importers would lose the declaration; for an executable it is not an error, and the package then embeds nothing (the previous behaviour), since nothing normally imports one. `scripts/ci/interface-embed-e2e.sh` now checks that a dotnet or JVM executable embeds an interface that names `main`; a native executable writes its interface beside the binary.

## Results

`tir_build_self_test.l` pins the protected type's defaults; the lyric-ui `Ui.Host.Web::router` body builds, and so do the `Lyric.CliBuildSelfTest` bodies that construct `Cli.ResolvedManifestDeps`. A native project build shares one store of carried defaults across its packages (D617).
