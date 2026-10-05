# Dotnet: reified generic opaque types (#8187, D177)

- A generic opaque type is now a generic class on `--target dotnet`, like a generic record, so `Opq[Int]` is stored unboxed and a library function returning `Opq[Int]` resolves from a restored consumer.
- A consumer-side specialisation that reads a restored generic opaque type's fields is T0165 at the access (the representation is internal to the declaring assembly); call it through a non-generic function in the library.
- Tests: `generic_opaque_self_test.l` on all targets; `generic-opaque-restored-e2e.sh`.
