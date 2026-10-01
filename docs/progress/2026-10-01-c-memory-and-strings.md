# C memory and C strings on every target (D161)

C APIs that take `const char*` can now be called from every target. This
is the next step toward the docs/65 U5 desktop webview host.

- **Intrinsics.**
  - `nativeLoadByte(p, offset): Byte` and
    `nativeStoreByte(p, offset, value): Unit` read and write the byte at
    `p + offset`.
  - The type checker checks arity (T0042) and argument types (T0043).
  - The mode checker confines both to `@unsafe_ffi` functions and
    `_kernel_native/` packages (N0100).
  - Lowering:
    - MSIL: `ldind.u1` / `stind.i1`.
    - JVM: an FFM `MemorySegment.ofAddress(...).reinterpret(1)` with
      `get` / `set` through `ValueLayout.JAVA_BYTE`.
    - Native: `getelementptr i8` with `load` / `store`.
- **`Std.Ffi`.**
  - `allocate`, `release`, `toCString` and `tryFromCString`, all
    `@unsafe_ffi`.
  - Memory comes from the C heap through `Std.FfiHost`, a
    `@library("c")` kernel binding `malloc` and `free`, so one source
    serves every target.
- **Bootstrap.**
  - The released seed predates `@library`, so it cannot compile
    `Std.FfiHost`.
  - Packages marked `# seed: current` in `lyric.full.toml` are left out
    of the seed-built stage-1 bundle.
  - The compiler stage 1 produces then rebuilds the full bundle
    (stage 2, `stage-selfhosted-stdlib.sh`). The marker comes off once
    a release that includes D161 becomes the seed.
- **Tests.** `extern_cbinding_self_test.l` runs on dotnet, JVM and native
  and covers:
  - byte round trips through C memory;
  - `strlen` of `toCString` output, including multi-byte UTF-8;
  - string round trips;
  - `None` for the null pointer and for invalid UTF-8.
