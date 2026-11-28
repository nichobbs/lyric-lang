# An impl whose target is a union runs on dotnet and the JVM (D867)

`impl Named for Shape` and `impl[T] Holder[T] for Wrap[T]` over a union were accepted and then failed at run time on every target (#9470, part of #7791). On dotnet the impl's methods now sit on the union's abstract base (with their MethodDef rows accounted for); on the JVM the sealed union interface extends the implemented interface and carries the impl methods as default methods, and a call on a union value is an interface call. Native is the next slice (D868). Covered by `generic_interface_self_test.l` on both targets.
