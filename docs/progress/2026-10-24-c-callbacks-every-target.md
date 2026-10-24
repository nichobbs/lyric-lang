# C callbacks through `@library` bindings on every target (D229)

A Lyric closure passed to a callback parameter of an `@library` extern func
is now a C function pointer on `--target dotnet` and `--target jvm`, as it
already was on `--target native`, with the same source surface: a callback
type carries a `NativeUserdata` slot (or a trailing `NativePtr[Byte]`), and
the same closure passed as the userdata is what C hands back.  Prerequisite
for embedding the wasmtime C API in a plugin host (docs/69 phase P5).

- **Pipeline** (`Lyric.Pipeline.pipeCBindingsToFuncs`): callback and
  `NativeUserdata` parameters lower to `NativePtr[Byte]`; one body-less
  `@__cbtrampoline` function per callback parameter; each call of such a
  binding in its package is rewritten to the `__lyric_cb_fnptr`,
  `__lyric_cb_ud` and `__lyric_cb_call` intrinsics.
- **MSIL**: trampolines are static `[UnmanagedCallersOnly]` methods (the
  writer's first `CustomAttribute` rows, with the table's sorted bit),
  addressed with `ldftn`; the userdata is a `GCHandle`.  A `NativePtr` now
  boxes as `System.IntPtr`, so closures take and return pointers.
- **JVM**: trampolines are static methods behind lazily made
  `Linker.upcallStub`s in `Arena.global()`; the userdata is a key in the
  shared `Lyric/Lyric$Callbacks` handle table.
- **All targets**: `NativeUserdata` is a built-in type everywhere;
  `nativeKeepCallback(f)` / `nativeReleaseCallback(p)` pin a closure for a C
  library that keeps its callback (ARC retain/release on native); T0181 is
  checked off native; callback signatures are checked by T0151; T0184 (new)
  rejects a closure passed to another package's C binding on the managed
  targets.
- **Tests**: `lyric-compiler/lyric/extern_callback_self_test.l` against
  `lyric-compiler/lyric/testdata/lyriccbtest.c` on dotnet, the JVM and native
  (`scripts/ci/extern-callback-e2e.sh`, run from the dotnet and JVM C-binding
  CI steps and `native-backend-self-tests.sh`); new `typechecker_self_test.l`
  cases.
- **Docs**: language reference §11.6/§11.7, book chapter 13 §13.10 and
  appendix B.
