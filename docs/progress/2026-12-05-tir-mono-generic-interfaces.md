# The TIR monomorphiser instantiates generic interfaces and impls (docs/70 phase 3c, mono slice 2)

Decision: D513.

## What shipped

- `Lyric.Tir.Mono` makes an instance of a generic interface, retargets a call through it (`Callee.Interface` with the instance and its method entry), keeps the impls of non-generic targets with their interface mapped to the instance, and instantiates each `impl[T]` block at every instance of its target (members instantiated, instance impl recorded in the instances package).
- The builder's interface symbol entry carries the interface's parameter count.
- `tir_mono_self_test.l`: a call through `Holder[Int]` and an `impl Holder[Int] for IntBox`; `impl[T] Holder[T] for Box[T]` at `Box[Int]` and `Box[String]`.
