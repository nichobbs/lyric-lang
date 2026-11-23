# An importing package sees what a project dependency's derives generate (docs/70 phase 3a, #8613)

**Status:** shipped; both project bridges.

## Context

`Xp.Api.Person.fromJson(body)` and `address.toJson()`, where `Person` and `Address` are `@generate(Json)` records of another project package (`scripts/ci/derive-json-cross-package-jvm-e2e.sh`, #7502), were stopped by the TIR gate (#9282): "the checker gave no usable type for an expression the checker could not type". A package's derives run on its own file when it is compiled, so the checker of the package itself sees the generated `toJson`/`fromJson`. The items a project package shows the packages that import it, however, were taken from its file before the derive ran, so the checker of an importer had no such members, gave the call no type, and left it to the backends, which resolve the name.

## Decision

The items a project package shows its importers are those of its file after its derives are expanded: `Lyric.Pipeline.pipeDerivedItemView` runs `deriveFileWithImports` on the package file with the derive inputs the package's own compile uses (the items of every registered package) and keeps the cross-package items. `Msil.Bridge.projectFrontEnd` builds `inBundleItems` from it, and `Jvm.Bridge` rebuilds the entry and sibling packages' `ImportedPackage` items from it after the registry is complete.

## Consequences

The checker types a dependency's derived members like any declared member, with no backend special case. Each project package is derived once more (the view); the package's own derive on compile is unchanged. Test: `scripts/ci/derive-json-cross-package-jvm-e2e.sh` (both targets) under the gate.
