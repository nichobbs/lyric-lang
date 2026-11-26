# `--target native` lays out an impl of a generic interface for a generic record (#7791, D864)

## What shipped

- `impl[T] Holder[T] for Box[T]` runs on native: a `Box[Int]` and a `Box[String]` used as `Holder[Int]` and `Holder[String]`, calls through the interface and a default method inherited through it (`genericifaces_generic_impl.l`: the same output from the AST and TIR paths, clean under AddressSanitizer). `genericImplVtable` reads the impl's method names from the interface instance's bare name.
- `N0105` is for the generic impls that path does not handle (a generic union target), covered by `genericifaces_unsupported_impl.l` in `native-via-tir-e2e.sh`.
- Fixed, on every target: a default method copied into a generic implementor had no callee on a concrete call (#9454): the copy shared the interface member's span; it has its own now.
