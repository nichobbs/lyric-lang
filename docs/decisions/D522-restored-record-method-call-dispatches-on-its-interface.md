# D522 - A call of a restored record's interface method dispatches on the interface in the TIR (docs/70 phase 3a, #8613)

**Status:** shipped; extends D389.

## Context

`cross_package_generics_self_test.l` was the last I0003 of the census. A package restored from a compiled DLL keeps no `impl` member of its own: the checker resolves `m.describe(e)`, with `m: MemStore` and `impl Store for MemStore { func describe }` in the dependency, to the interface's declaration `Store::describe`, so the call's callee is an interface method while the receiver is a record. The builder registered the callee's signature once, at the first receiver type it met, so a body that called `describe` through `Store` and through `MemStore` had one call whose receiver the verifier found to be another type than the signature's (`call-arg-type: expected #379 (Store) but found #380 (MemStore)`); which of the two failed depended on their order.

## Decision

`buildMethodCall` takes the interface that declares the callee when the callee's DefPath is `Pkg::Iface::member` and `Iface` is a non-generic interface, and the checker did not already record an interface receiver. The call is then the same node an interface-typed receiver gets: the receiver is converted up to the interface (`coerceArg`, the existing interface upcast), the callee is `Interface`, and the signature is registered against the interface type. Backends dispatch on the interface for the record, as they do for an interface-typed value.

`LYRIC_VERIFY_IR=1` now prints, under each I0003 example, the DefPath key of every `#N` symbol the message names (`symbols: #379 = CpGen.StoreLib::Store, ...`), which is how this was found.

## Not covered

A generic interface keeps its previous path (an interface call carries no type arguments yet).
