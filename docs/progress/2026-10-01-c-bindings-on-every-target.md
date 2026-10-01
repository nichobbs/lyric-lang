# C bindings on every target (D158)

`@library("name") extern func f(...): R = "symbol"` now calls a C
library on `--target dotnet` and `--target jvm`, as well as native.

- **Pipeline.** `Lyric.Pipeline.pipeCBindingsToFuncs` turns each
  `@library` extern func into a body-less function marked
  `@__cbinding(lib, symbol)`, so the backends type and call it as an
  ordinary package function.
- **MSIL.** The emitter writes a `pinvokeimpl` method with an `ImplMap`
  row and a `ModuleRef` per library (new metadata tables 0x1A and 0x1C in
  `Msil.Tables`). `NativePtr[T]` is `native int`; `nativeNullPtr()` is
  `ldc.i4.0; conv.i`.
- **JVM.** Each binding is a static method that binds a Foreign Function
  & Memory downcall handle on first call, caches it in a private static
  field, and calls it with `invokeExact`. `NativePtr[T]` is a `long`,
  converted to a `MemorySegment` only across the call. JARs carry
  `Enable-Native-Access: ALL-UNNAMED`.
- **Native.** A `@library` other than `"c"` adds `-l<name>` to the link
  (`-l:<file>` for a file name, the path itself for a path).
- **Library names.** A base name gets each platform's file naming; a name
  containing `.` or `/` (`"libm.so.6"`) is passed to the loader as
  written, for system libraries whose unversioned `.so` is a linker script.
- **`Float`** is not admitted yet (#7966): MSIL and native carry it as a
  64-bit double, so the boundary would pass the wrong bits.
- **Checker.** `NativePtr` and `nativeNullPtr` type on every target.
  T0149 (no `@library` off native), T0150 (malformed or repeated
  `@library`), T0151 (a type that cannot cross the call).
- **CI.** Every JVM job runs on JDK 22, which the FFM API needs. Class
  files stay at Java 21's major version 65.
- **Tests.** `extern_cbinding_self_test.l` calls libc on dotnet and the
  JVM; `typechecker_self_test.l` covers T0149–T0151.

Follow-up: #7930 (`"c"` on Windows .NET).
