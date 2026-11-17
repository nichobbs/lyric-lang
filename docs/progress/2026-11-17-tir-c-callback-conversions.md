# docs/70 phase 3a: closures passed to C callbacks (D494)

A closure passed to an `extern func` callback parameter is a `CvCallback` conversion, and one passed as the userdata pointer is a `CvClosureAsPointer`. The builder emits them, the verifier checks their shapes, and the interface format carries them (tags 13 and 14). Removes the callback share of the "argument conversion" I0002 kind (52 self-test sites in the wide census of 2026-11-17). Remaining argument-conversion shapes: `slice[T]` where `array[N, T]` is expected, record element to `Int`, `Long` to `Int`/`Nat`.
