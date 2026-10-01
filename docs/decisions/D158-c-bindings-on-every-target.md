# D158 — C bindings on every target: `@library` extern funcs

**Status:** accepted, implemented

Prerequisite for docs/65 phase U5 (desktop webview host), which needs a C
library (`webview`) from both managed targets. Extends D-N-007 (native
`extern func`) and §11.6 of the language reference.

## Context

`extern func f(...): R = "symbol"` binds a C symbol, but only
`--target native` could call one. On the managed targets the item was
inert: it type-checked and the MSIL and JVM backends panicked on it.
The managed targets reached the host platform only through
`@externTarget` and auto-FFI, which bind .NET or JVM methods, not C
functions. A UI host that embeds a native webview, or any program that
needs a C library, had no route on .NET or the JVM.

Both managed runtimes can call C directly. .NET has P/Invoke, encoded in
metadata as a `pinvokeimpl` method with an `ImplMap` row. The JVM has the
Foreign Function & Memory API, final in JDK 22.

## Decision

1. **`@library("name")` makes an `extern func` a C binding on every
   target.** The argument is the library's base name; each runtime
   applies its platform's file naming and search path. `"c"` is the
   platform C library. A name containing `.` or `/` is a file name or
   path, passed to the loader as written: a system library such as
   glibc's `libm` has no loadable unversioned `.so` on a machine without
   development packages (`libm.so` is a linker script), so it is bound as
   `"libm.so.6"`.
2. **Lowering.** The pipeline (`Lyric.Pipeline.pipeCBindingsToFuncs`)
   turns each `@library` extern func into a body-less function marked
   `@__cbinding(lib, symbol)`. Signature collection, typing and call
   lowering then treat it as an ordinary package function, and only its
   emission differs:
   - **MSIL**: a `pinvokeimpl` static method (`PreserveSig`, no body)
     with an `ImplMap` row (`NoMangle | CallConvPlatform`) naming the
     library's `ModuleRef`. `"c"` is written as `libc`, which the .NET
     runtime maps to the real C library on Linux, where `libc.so` is a
     linker script.
   - **JVM**: a static method that looks the symbol up through
     `Linker.nativeLinker()` (the default lookup for `"c"`, otherwise
     `SymbolLookup.libraryLookup(System.mapLibraryName(lib),
     Arena.global())`), builds the `FunctionDescriptor` from `ValueLayout`
     constants, and calls the cached `MethodHandle` with `invokeExact`. The
     handle is bound on the first call and kept in a private static
     field, so a missing library or symbol fails at the call, never when
     the package's host class loads.
   - **Native**: unchanged codegen; the library is added to the link as
     `-l<name>` (`"c"` adds nothing).
3. **Types are those every target passes the same way.** `Int`, `Long`,
   `Byte`, `Double` and `NativePtr[T]`, plus `Unit` as a result (`T0151`
   otherwise). `Float` is excluded for now: MSIL and native carry it as a
   64-bit double, so a C `float` would receive the wrong bits; #7966 adds
   the conversion at the boundary (docs/67 G1 makes `Float` 32-bit on
   MSIL and native). The restriction is the managed targets' own: on
   native a `@library` binding keeps the full `extern func` surface
   (callbacks, `String`), so T0151 is reported only off native.
   Strings, records and callbacks are not marshalled on the managed
   targets: each would need per-target ownership rules
   (who frees a returned string, how long a callback lives) that a
   pointer-and-integer signature makes the C side's explicit
   responsibility instead. A program builds such conversions in Lyric over
   `NativePtr`.
4. **`NativePtr[T]` and `nativeNullPtr()` type on every target.** A
   pointer is an opaque native-sized integer on .NET and a `long` address
   on the JVM, converted to a `MemorySegment` only across the downcall.
   `nativeAddrOf` and `NativeWeak` stay native-only (#7910). The `N0100`
   boundary is unchanged: pointer values live in `@unsafe_ffi` functions.
5. **Diagnostics.** `T0149`: an `extern func` without `@library` on a
   managed target. `T0150`: a malformed or repeated `@library`. `T0151`:
   a type that cannot cross a C binding.
6. **JDK 22 for C bindings on the JVM.** Class files stay at major
   version 65 (Java 21), so programs without a C binding still run on
   Java 21. A program that uses one needs a JDK 22 or later runtime. Every
   CI JVM job moves to JDK 22. Emitted JARs carry
   `Enable-Native-Access: ALL-UNNAMED`, and `lyric test` adds
   `--enable-native-access=ALL-UNNAMED` when it runs a JAR with `-cp`, so
   the JDK's restricted-method warning does not fire.

## Consequences

- `extern_cbinding_self_test.l` calls libc (`abs`, `labs`, `toupper`,
  `ldexp`, `malloc`, `memset`, `free`) and `libm.so.6` by file name on
  dotnet, the JVM and native in CI, with `Int`, `Long`, `Double` and
  `NativePtr` arguments and results.
- `typechecker_self_test.l` covers T0149–T0151 and the managed-target
  typing of `NativePtr`.
- `"c"` on .NET relies on the runtime's `libc` mapping, which covers
  Linux and macOS. Windows has no library named `libc`; binding the C
  runtime there needs `@library("ucrtbase")` today. #7930 tracks a
  platform-neutral spelling.
- U5 can bind the `webview` C library from Lyric on both managed targets.
