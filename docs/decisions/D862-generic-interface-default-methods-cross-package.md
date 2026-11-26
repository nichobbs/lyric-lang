# D862: a default method of another package's generic interface is callable on a concrete implementor

Status: accepted (#9441, part of #7791).

## Decision

D861 made a default method of another package's interface callable on a concrete implementor for a plain interface. The same call on a *generic* interface (`impl Holder[Int] for IntBox`, `IntBox(v = 1).twice(9)` with `twice` a default method of `HLib.Holder[T]`) failed at run time, and in one shape did not compile.

- **JVM, the library side:** a generic interface's own default method was emitted with its type parameters unerased (`HLib.T twice(HLib.T)`), so no call site's erased descriptor (`twice(Object)Object`) found it (`NoSuchMethodError`, through the interface type as well as on a concrete implementor). `lowerImplMethod` now receives the interface's parameters, as the abstract methods' emission already does.
- **TIR builder:** a call of such a method on a concrete receiver was built as an interface call with no interface arguments, which disagreed with an interface-typed call of the same method in the same file (I0003, `call-arg-type`). `ifaceOwnerOfMethod` now takes the receiver's type and answers the generic interface at the arguments the receiver's `impl` gives it (`genericIfaceOfImpl`), so the call is a dispatch on that instance, converted up to it, exactly as for a plain interface.
- **dotnet:** a call on a type that declares no method of that name dispatches on the slot of a generic interface the type implements (`genericIfaceDefaultEntryMsil`): a `callvirt` of a TypeSpec-parented MemberRef built from the impl's interface arguments (`ImplEntryMsil.ifaceTypeArgs`), through `lowerGenericRecvCallMsil`, the helper extracted from the generic-receiver arm of `lowerMethodCallMsil`.

## Not done

Native: the backend rejects generic interfaces (T0217/N0007) until the TIR lowering of `TPackage.impls` lands (D513, #9426); the native slice of #7791 covers this case.
