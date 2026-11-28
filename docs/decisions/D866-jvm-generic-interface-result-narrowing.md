# D866: a generic-interface call's result is narrowed to the instantiated type on the JVM

Status: accepted (#9459, part of #7791).

## Decision

The JVM erases a generic interface (D860): its methods take and return `Object`. A call through `Holder[String]` therefore lowered to an `Object`-typed value, and a binary operator over two such results (`h.get() + h.get()`) could not tell numeric addition from concatenation, so the build stopped with J008. A single erased operand worked only because the other side's type decided the operator.

The checker now records, for a call through a generic interface whose result the instantiation fixes to a primitive or `String` (`recordGenericIfaceResult`), the result's type name under `ifaceResultSiteKey(span)` in `SymbolTable.memberRecvClasses`. `Jvm.Bridge` seeds it as `~recv~ifaceres|<span key>`, and `Jvm.Codegen.narrowGenericIfaceResultJvm` casts or unboxes the call's result to that type straight after the call (`emitUnboxObjectTo`). The call is then an `Int`, `Long`, `String`, and so on to every consumer, so `+`, `<`, `*` and the rest need no special case. Results that are records, unions or other generic instances already narrow through the receiver-class map when a member is read, and are unchanged.

dotnet reifies the interface and native lays it out per instantiation, so neither needed a change.

## Verification

`generic_interface_self_test.l` (dotnet and JVM) adds an operator test over `Holder[Int]`, `Holder[String]` and `Holder[Long]` results; `scripts/ci/native-via-tir/genericifaces.l` adds `h.get() + h.get()` for `Holder[String]` and runs on native (AST and TIR paths, AddressSanitizer) with the same output.
