# A default method copied into a generic implementor has a callee on a concrete call (#9454, D865)

## What shipped

- `Lyric.ImplDefaults` gives the copy of an interface default its own span (D865). `b.twice(9)` on a `Box[Int]`, with `twice` a default of `interface Holder[T]` and `impl[T] Holder[T] for Box[T]` in one file, built with I0002 on dotnet, the JVM and native; it runs on all three now.
- `generic_interface_self_test.l`: the inherited default on a `Wrapped[Int]` and a `Wrapped[String]`, on dotnet and the JVM.
