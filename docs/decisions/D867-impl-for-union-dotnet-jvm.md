# D867: an impl whose target is a union, on dotnet and the JVM

Status: accepted (#9470, part of #7791).

## Decision

The checker accepted `impl Named for Shape` and `impl[T] Holder[T] for Wrap[T]` where `Shape` and `Wrap[T]` are unions, and no backend lowered it: a value of a case used as the interface failed at run time (`TypeLoadException: Method 'name' in type 'Shape_Circle' does not have an implementation` on dotnet, `ClassCastException` on the JVM, an `N0007` invariant violation on native). A union is a type of its own in the language, so an impl for it must work on every target.

- **dotnet:** a union is an abstract base class with one class per case. The impl's `InterfaceImpl` row was already on the base; its methods were attached to no type. `Msil.Codegen.injectImplMethodsIntoUnion` adds them to `MUnion.methods`, which `lowerMUnion` emits on the base (they were emitted with a static signature, so an instance method now gets the instance one), and `addPackageTokens` counts and registers their MethodDef rows before the base's own `.ctor`, in the order `lowerMUnion` emits them. The CLR wires each case's inherited method to the interface by name and signature, and a generic union's methods use the VAR form like a generic record's.
- **JVM:** a union is a sealed interface with one class per case. The sealed interface now **extends** the interface the impl names and holds the impl's methods (and bridges) as **default methods**, which every case inherits (`LSealedUnion.implementsIfaces`, `implMethods`). A call on a union value is an `invokeinterface` (`markUnionTargetSigsIfaceJvm`), not the `invokevirtual` a record gets.
- **Defaults and generics:** a default method of the interface is inherited by the union's impl as for a record, and `impl[T] I for Wrap[T]` over a generic union runs at each instantiation, both on the same code.

## Not done

Native: an impl for a union is still an `N0007` invariant violation (non-generic) or `N0105` (generic, D864). Its vtables and impl methods are keyed on record definitions (`registerImplVtables`, `recordIrNameOfType`, `recIrById` in the TIR environment); the native slice is D868.

## Verification

`generic_interface_self_test.l` (dotnet and JVM) adds a non-generic union implementing a plain interface (through the interface, on the union value, its inherited default) and a generic union implementing `Holder[T]` at `Int` and `String`.
