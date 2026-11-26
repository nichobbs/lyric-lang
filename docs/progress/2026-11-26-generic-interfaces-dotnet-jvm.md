# Generic interfaces on dotnet and the JVM (#7791)

Decision: D860.

## What shipped

- Checker and TIR: a call through a `Holder[Int]` value has a call site and builds as `Callee.Interface` with the interface's arguments; a default method of a generic interface is found at the impl's arguments (`ImplPair.ifaceArgs`).
- `MiddleEndOptions.genericInterfaces`: T0217 is dropped for dotnet and the JVM and kept for native.
- `Lyric.ImplDefaults` copies a generic interface's default methods into an impl with the arguments substituted (`Lyric.Mono.substGenericsInDecl`).
- MSIL: reified generic interface TypeDefs (arity suffix, GenericParam rows, VAR signatures), InterfaceImpl over a TypeSpec, TypeSpec-parented calls; restored generic interfaces register like restored generic records.
- JVM: bridges that box and unbox for primitive-typed impl methods, narrowing of generic-interface receivers, and cross-package impls.
- `TPackage.impls` (`TImplDecl`): every impl block's interface, arguments and members, built, verified and kept by the TIR passes, for the TIR monomorphiser (docs/70 phase 3c, slice 2).
- A value is accepted as a `Holder[Int]` only when its impl gives `Int` (a `Holder[Long]` implementor is T0043), so the backends never call an implementor at another instantiation.
- Tests: `generic_interface_self_test.l` (both targets, and ILVerify), four tir_build cases, a typechecker case, and `testdata/reject/generic_interface_*`.

## Remaining

Native (`--target native` still reports T0217), bounds that name a generic interface, and the TIR monomorphiser's generic-interface slice (docs/70 phase 3c).
