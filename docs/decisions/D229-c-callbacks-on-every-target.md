# D229 — C callbacks through `@library` bindings on every target

**Status:** accepted, implemented

Extends D158 (C bindings on every target) and D161 (C memory and strings),
and the native callback rule of §11.6 (N4.5, D-progress-551/552, D189).
Prerequisite for docs/69 phase P5: embedding the wasmtime C API in a plugin
host, where wasmtime calls host functions through C function pointers with a
`void *env` userdata.

## Context

On `--target native` an `extern func` parameter of function type with a
userdata slot (a `NativeUserdata` parameter, or a trailing `NativePtr[Byte]`)
takes a Lyric closure: the backend passes a synthesised C trampoline for the
callback, and the closure pointer itself for the userdata argument, so C
hands the closure back to the trampoline on every call.  On `--target dotnet`
and `--target jvm` D158 stopped at integers, doubles and pointers: a callback
parameter was `T0151`, because each managed runtime needs its own way to turn
a closure into a C function pointer and its own rule for keeping the closure
alive.  `NativeUserdata` did not even exist off native.

## Decision

1. **Same source surface on every target.**  A callback parameter of an
   `@library` binding takes a closure of the callback's type without the
   userdata slot, and the same closure passed for a `NativePtr[Byte]` or
   `NativeUserdata` parameter is the userdata, exactly as on native.
   `NativeUserdata` is a built-in type on every target.  A callback's
   parameters and result are the D158 types (`Int`, `Long`, `Byte`, `Float`,
   `Double`, `NativePtr[T]`, `NativeUserdata`; `Unit` as a result); a function
   type as a result, or nested in a callback signature, is `T0151`.  `T0181`
   (a function-typed parameter with no userdata slot) is now checked on every
   target.

2. **The managed call site is rewritten in the pipeline.**
   `Lyric.Pipeline.pipeCBindingsToFuncs` lowers each callback parameter and
   each `NativeUserdata` parameter of a binding to `NativePtr[Byte]` (what it
   is in C), synthesises one body-less trampoline per callback parameter
   (`__lyric_cbt_<f>_<i>`, marked `@__cbtrampoline(<slot>)`, with the
   callback's C signature), and rewrites every call of such a binding in its
   package to explicit intrinsics: `__lyric_cb_fnptr(cb, "<trampoline>")` for
   a callback argument, `__lyric_cb_ud(x, "<temp>")` for every argument of a
   `NativePtr[Byte]` or `NativeUserdata` parameter, and an enclosing
   `__lyric_cb_call(call, "<temp>"...)`.  A pointer argument passes through
   `__lyric_cb_ud` unchanged; only a closure is pinned.  The backends lower
   only those intrinsics, so call resolution, argument coercion and the
   binding's emission (D158) are unchanged.

3. **MSIL: an `UnmanagedCallersOnly` trampoline and a `GCHandle`.**  Each
   trampoline is a static method of the package class marked
   `[UnmanagedCallersOnly]` (a `CustomAttribute` row on its `MethodDef`), and
   `__lyric_cb_fnptr` is `ldftn` of it, which yields a native-callable
   address with the platform calling convention and no marshalling stub.
   This is the reverse-P/Invoke form Native AOT supports, and the only one
   that fits: `Marshal.GetFunctionPointerForDelegate` rejects generic
   delegate types, and every Lyric closure is a generic `Func`/`Action`.  The
   userdata is `GCHandle.ToIntPtr(GCHandle.Alloc(closure))`; the trampoline
   recovers the closure with `GCHandle.FromIntPtr(ud).Target`, boxes the
   other arguments for the uniform delegate ABI, invokes it and unboxes the
   result (a `Unit` closure may be an `Action` or a `Func`, so both are
   tried, as for an erased function value).  A `NativePtr` now boxes as
   `System.IntPtr`, so a closure taking or returning a pointer round-trips.
   A value erased to `object` at a userdata argument is tested at run time
   (`isinst System.Delegate`) so a boxed pointer still passes as a pointer.

4. **JVM: an upcall stub over a static trampoline and a handle table.**  Each
   trampoline is a static method; a generated getter makes its upcall stub
   on first use with `Linker.nativeLinker().upcallStub` over a
   `MethodHandle` from `MethodHandles.lookup().findStatic`, caches the
   address in a static field, and binds the stub to `Arena.global()`.  The
   stub therefore lives as long as the process, one per callback parameter,
   like a native trampoline function; two threads racing the first call may
   each make one, and both stay valid.  Pointer parameters cross the stub as
   `JAVA_LONG`, which every 64-bit C ABI passes as it passes a pointer, so the
   trampoline sees the `long` a `NativePtr` is in Lyric.  The userdata is a
   key into the handle table of the shared class `Lyric/Lyric$Callbacks` (a
   `ConcurrentHashMap` keyed by an `AtomicLong` counter, emitted once per
   bundle like `Lyric$Lambda`, so a key kept in one package resolves in
   another); the trampoline looks the closure up and invokes it through
   `Lyric$Lambda.invoke`.  A key that is not live is an
   `IllegalStateException`.  The intrinsics emit no branch in user code, so no
   stack map frame sees the call's other arguments on the operand stack.

5. **Lifetime.**  The callback parameter needs none: a trampoline, and on the
   JVM its stub, lives as long as the program.  A closure passed directly as
   the userdata is valid until the C function returns: the managed targets
   pin it for the call (a `GCHandle`, a table key) and release it afterwards,
   and native borrows it, as before.  A callback the library keeps and calls
   later needs a userdata that outlives the call, so two intrinsics, on every
   target and confined by `N0100`, pin and unpin a closure explicitly:
   `nativeKeepCallback(f): NativePtr[Byte]` (a `GCHandle` on .NET, a table
   entry on the JVM, an ARC retain on native) and
   `nativeReleaseCallback(p)`.  They are intrinsics rather than `Std.Ffi`
   functions because `keep` takes a closure of any function type, which no
   stdlib signature can express; each backend implements them directly.
   Calling a userdata after its call returned or after its release, or
   releasing one twice, is undefined on .NET and native and an
   `IllegalStateException` on the JVM.

6. **Threads and panics.**  C may call a callback from any thread, during
   the call that passed it or, for a kept callback, until its release: the
   .NET runtime and the JVM attach a foreign thread on entry to an
   `UnmanagedCallersOnly` method or upcall stub.  A panic or exception that
   escapes a callback ends the process on every target (the .NET runtime
   fails fast, the FFM API terminates the JVM, native aborts), since it cannot
   unwind through C frames.

7. **`T0184`: a closure reaches a C binding only from its own package on the
   managed targets.**  The adaptation needs the binding's declaration at the
   call site, and the pipeline rewrites one package at a time, so passing a
   closure to another package's binding (a callback argument, or a closure
   for a pointer parameter) is `T0184` on `--target dotnet` and `--target jvm`.
   The declaring package exports a wrapper that takes the closure, the
   pattern a kernel already follows.  Native passes the closure itself and
   has no such limit.

## Consequences

- `extern_callback_self_test.l` runs on dotnet, the JVM (JDK 22) and native
  against `testdata/lyriccbtest.c`: a callback called many times, userdata
  first or last, `Int`, `Long`, `Double`, `Float`, `Byte` and pointer
  arguments and results, a kept callback called on a later C call and
  released, a kept pointer passed through C unchanged, and a callback called
  from a second thread.  `scripts/ci/extern-callback-e2e.sh` builds the
  library and runs it; CI runs it in the dotnet and JVM C-binding steps and
  in the native backend self-tests.
- `typechecker_self_test.l` covers the managed typing, `T0151` on callback
  signatures, `T0181` off native, the pin intrinsics and `T0184`.
- Strings: a wasmtime embedding passes `const char*` with `Std.Ffi.toCString`
  and reads NUL-terminated ones back with `tryFromCString` (D161); a
  pointer-and-length string (wasmtime's `wasm_name_t`, error messages) is
  read byte by byte with `nativeLoadByte` and decoded with
  `Std.Encoding.tryDecodeUtf8`.
- A wasmtime host function (`wasmtime_func_callback_t`, env first) is a
  callback `(NativeUserdata, NativePtr[Byte], NativePtr[Byte], Long,
  NativePtr[Byte], Long) -> NativePtr[Byte]` with its closure kept by
  `nativeKeepCallback` for the life of the `wasmtime_func_t`.  A C finalizer
  callback for the env (wasmtime's `finalizer`) would receive the env of a
  different closure type, so the host passes a null finalizer and releases
  the kept pointer itself when it drops the store.
