# Native: generic protected types (#7864, D176)

- `--target native` builds `protected type Cell[T]`: one heap layout per instantiation (fields with `T` substituted, the lock buffer, a destructor that frees it), generic lock/unlock wrapper functions around the desugared bodies, construction that allocates the lock buffer.
- `N0008` and its pre-pass are gone.
- Tests: an ASan case in `llvm_self_test_n34.l`; `generic_protected_self_test.l` now runs on native too.
- Still open: invariant re-checking on native; value generic parameters on protected types (#8149).
