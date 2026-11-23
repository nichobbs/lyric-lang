# A call through a type to a body method builds as the method call (D763)

The checker records the callee and shape of `T.m(x, args)` (D181) under the call's node and the typed IR builder builds it as `x.m(args)`. `type_qualified_method_self_test.l` builds on dotnet, the JVM and native with no I0002.
