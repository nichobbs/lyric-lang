# `.toArray()` of a slice is typed as the slice (D601)

The slice member table had no `.toArray()`, so a call on a slice had no callee or type and the TIR builder counted it unbuilt (16 bodies in `lyric-generator-sdk`'s tests); the error type also hid `.count` misuse of the result. It is now `() -> slice[T]`, the documented identity. The hidden misuse in generator-sdk's tests (five `.count` reads, three untyped shared enum case bindings) is corrected. Test: the `slice_to_array` shape in `scripts/ci/tir-builder-shapes-e2e.sh`.
