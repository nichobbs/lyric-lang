# A default method of another package's generic interface runs on a concrete implementor (#9441, D862)

## What shipped

- JVM: a generic interface's default methods are emitted with the interface's type parameters erased (`twice(Object)Object`), so both a call on a concrete implementor and a call through `Holder[Int]` resolve. Before, the descriptor named `HLib.T` and every call threw `NoSuchMethodError`.
- TIR builder: a call of a generic interface's method on a concrete receiver is built as a dispatch on the interface at the arguments the receiver's `impl` gives it, so it agrees with an interface-typed call of the same method in one function (no I0003).
- dotnet: the call dispatches on the generic interface's slot through a TypeSpec-parented MemberRef built from `ImplEntryMsil.ifaceTypeArgs` (`lowerGenericRecvCallMsil`, extracted from the generic-receiver arm).
- `default_method_cross_package_self_test.l` covers a generic interface from another package on both targets.

Native still rejects generic interfaces (T0217/N0007); it lands with the native TIR lowering of `TPackage.impls` (#7791).
