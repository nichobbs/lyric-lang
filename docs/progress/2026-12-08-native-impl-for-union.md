# native: an impl whose target is a union gets a vtable (D868)

`impl Sized for Shape` over a (non-generic) union is laid out on `--target native` (#9470, part of #7791): the union stays a heap object, its vtable is built like a record's and the TIR environment keys it. dotnet and the JVM ran it in D867. The generic union (`impl[T] I for Wrap[T]`) is still N0105. Covered by `scripts/ci/native-via-tir/unionimpl.l` in the native via-TIR e2e.
