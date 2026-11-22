# TIR builder: the JVM List host name carries its arity (D752)

A bracket literal passed where the JVM stdlib `List[T]` is wanted is retyped to that `List`, as on dotnet: `isListHostName` accepts `java.util.ArrayList`1` and `java.util.List`1`. `labelled_loops_self_test` builds 22 of 22 bodies. Self-test: `tir_build_self_test.l`.
