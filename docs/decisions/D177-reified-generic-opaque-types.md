# D177 - Reified generic opaque types on dotnet

**Status:** accepted, implemented (`--target dotnet`)

Resolves #8187.

## Context

A generic opaque type (`opaque type Opq[T] { v: T }`) was emitted on MSIL as one non-generic sealed class whose type-parameter fields were `object`. Two things followed:

- A restored consumer resolved `Opq[Int]` to a generic instantiation (`Opq<Int32>`) while the declaring assembly's signatures said `object`, so a call such as `mk(3)` failed with `MissingMethodException`.
- A value-type payload was never boxed or unboxed, so `Opq[Int]` produced invalid IL even in a single file.

## Decision

1. **Reify.** `reifyGenericOpaquesMsil` rewrites each generic, non-projectable `opaque type` with a body into the equivalent generic record before the MSIL entry points (`preRegisterPackageTypeNames`, `addPackageTokens`, `codegenMPackage`, and the restored-artifact registration). The existing generic-record machinery (GenericParam rows, `!n` fields, TypeSpec-parented members, docs/43) applies unchanged, in the declaring and the consuming assembly. The fields are internal (`FDA_ASSEMBLY`), as for any opaque type, not public. `@projectable` generic opaque types are unchanged.
2. **A cross-package specialisation cannot read the representation.** A consumer that specialises a restored generic function over an opaque type and reads its fields would fault at run time, since the fields are internal to the declaring assembly. The restored type registers no field references and the build fails with **T0167** at the access. The way out is a non-generic function in the declaring package. The alternatives (public accessors, which weaken the opacity guarantee of docs/01 that the JVM already relaxes; specialising in the declaring assembly, which needs a per-instantiation export mechanism) are not taken.

## Tests

`generic_opaque_self_test.l` (all targets) and `scripts/ci/generic-opaque-restored-e2e.sh` (restored dependency, T0167).
