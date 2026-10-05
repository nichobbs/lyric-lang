# Generic protected types on the native backend (#7864)

`--target native` now compiles `protected type Cell[T] { ... }`. Each
instantiation gets its own layout (user fields with `T` substituted plus the
trailing mutex field), destructor and lock/unlock wrappers around the
`T`-substituted member bodies; construction infers the type arguments like a
generic record's. See D-progress-1045.

The `N0008` diagnostic and its `Lyric.LlvmBridge` pre-pass are gone.
`generic_protected_self_test.l` joins the native lane of
`scripts/ci/native-backend-self-tests.sh`, and `llvm_self_test_n34.l` gains an
ASan case over two instantiations. docs/01 §7.5 and the native build paragraph,
the book's quick reference and concurrency chapter, and the status table in
`docs/10-bootstrap-progress.md` drop the native exception.
