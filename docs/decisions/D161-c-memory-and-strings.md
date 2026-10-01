# D161 — C memory and C strings on every target: byte intrinsics and `Std.Ffi`

**Status:** accepted, implemented

Prerequisite for docs/65 phase U5 (desktop webview host), whose C library
takes `const char*` arguments. Extends D158 (`@library` C bindings) and
§11.6/§11.7 of the language reference.

## Context

D158 lets every target call a C function whose parameters are integers,
doubles and pointers. Most real C APIs also take or return strings: a
NUL-terminated UTF-8 buffer in C memory. A Lyric `String` is a managed
object on .NET and the JVM and a reference-counted buffer on native, so it
cannot be handed to C as is, and the managed targets had no way to put
bytes into C memory or read them back. `NativePtr[Byte]` was an opaque
value on those targets.

## Decision

1. **Two intrinsics read and write one byte of C memory on every target.**
   `nativeLoadByte(p: NativePtr[Byte], offset: Long): Byte` and
   `nativeStoreByte(p: NativePtr[Byte], offset: Long, value: Byte): Unit`
   address `p + offset`. An `Int` offset widens. They are raw memory
   access, so the mode checker confines them like the other pointer
   intrinsics: only in `@unsafe_ffi` functions and `_kernel_native/`
   packages (`N0100`).
   - **MSIL**: `ldind.u1` / `stind.i1` on the native-int address.
   - **JVM**: `MemorySegment.ofAddress(p + offset).reinterpret(1)`, then
     `get` / `set` with `ValueLayout.JAVA_BYTE` (the FFM API D158 already
     requires).
   - **Native**: a `getelementptr i8` and a `load` / `store`.
2. **`Std.Ffi` builds C strings on those intrinsics.** `allocate(size)`
   and `release(p)` wrap the C library's `malloc` and `free` through a
   `@library("c")` kernel (`Std.FfiHost`), so a buffer belongs to the C
   heap and a C function may keep or free it, which managed memory never
   allows. `toCString(s)` copies the UTF-8 encoding of `s` into a new
   buffer and appends the NUL; `tryFromCString(p)` copies the bytes up to
   the NUL and decodes them, returning `None` for the null pointer or
   invalid UTF-8. Every function takes or returns a `NativePtr`, so all are
   `@unsafe_ffi`. `allocate` panics when `malloc` returns null, as other
   allocation failures do.
3. **Byte-at-a-time copying is the v1 cost.** A bulk copy (`memcpy` from a
   pinned array) would be faster but needs a pinning primitive on .NET and
   a heap-segment copy on the JVM, each a separate boundary. The strings
   C APIs take in practice (titles, URLs, paths) are short.

## Consequences

- A C binding that takes `const char*` is written once, for every target:
  `toCString` the argument, call, `release`.
- `Std.Ffi` is `@experimental` until C structs (docs/67 G3, D155) settle
  how wider values cross the boundary.
- Verified by `extern_cbinding_self_test.l` on dotnet, JVM and native:
  byte round trips through C memory, `strlen` of `toCString` results
  (multi-byte UTF-8 included), string round trips, and `None` for the null
  pointer and for invalid UTF-8.
