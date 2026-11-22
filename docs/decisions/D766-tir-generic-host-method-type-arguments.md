# A generic host method carries its type arguments, inferred from the call's arguments (docs/70 phase 3a, #8613)

**Status:** shipped; the metadata resolver, the builder and the interface format.

## Context

`Array.IndexOf<T>(T[], T)` and `ValueTuple.Create<T1, T2>(T1, T2)` (`auto_ffi_self_test`, 452 and 462) resolve through auto-FFI and run, but the host metadata resolver left a generic method out of the candidates (D387), so the typed IR builder had nothing to pick and the gate (#9282) stopped these bodies.

## Decision

- `ExternMemberSig.genericArity` counts the method's own type parameters; the signature names them `EIEMArg(index)` (a new `ExternIterElem` case, beside `EIEArg` for the owner's). The MSIL resolver keeps generic overloads, reading `STMVar` as `EIEMArg`. The JVM resolver reads erased descriptors, so a generic method there has `genericArity` 0 and its parameters are the erased types; its `typeArgs` stay empty.
- The builder infers the type arguments from the call's argument types, as the MSIL backend picks the instantiation: a bare `T` takes the argument's type, `T[]` the element of a slice or array, a generic host type its arguments pairwise; one bound to two different types is no fit, and one no argument binds leaves the call uncovered. `params` and `ret` are recorded already substituted, like the owner's arguments.
- `HostMemberRef.typeArgs` carries the arguments for a backend that instantiates the method. The interface format records them (format version 7) and the dump prints them.

## Consequences

`auto_ffi_self_test` 452 and 462 build. Tests: `tir_build_self_test.l` (a generic fake-host method), `iface_self_test.l` (the round trip).
