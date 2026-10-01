//! std/_kernel/ffi_host.l — C heap boundary for `Std.Ffi` (D161).
//!
//! The C library's `malloc(3)` and `free(3)`, bound with `@library("c")`
//! so one file serves every target: P/Invoke on .NET, a Foreign Function
//! & Memory downcall on the JVM, and a direct call on native (D158).
//! Memory from `hostAllocate` belongs to the C heap, so a C function may
//! keep it or free it, which managed memory never allows.
//!
//! Internal: only Std.Ffi should import this.
@axiom("malloc(3) and free(3) conform to their C standard contracts")
@io
package Std.FfiHost

@library("c")
extern func cMalloc(size: Long): NativePtr[Byte] = "malloc"

@library("c")
extern func cFree(p: NativePtr[Byte]): Unit = "free"

@unsafe_ffi
pub func hostAllocate(size: in Long): NativePtr[Byte] {
  cMalloc(size)
}

@unsafe_ffi
pub func hostRelease(p: in NativePtr[Byte]): Unit {
  cFree(p)
}
