//! std/_kernel_native/plugin_wasm_bind.l - the C bindings of the in-process
//! wasm host for native hosts: the same `lyric_wasmhost_*` symbols as the
//! managed twin's `@library` bindings, here bound in `lyric_rt.a`, which
//! links `lyric-rt/src/lyric_wasmhost.c` (it loads libwasmtime at run time,
//! so a native program needs no wasmtime to link).  docs/69 §9.3.
//!
//! The closure passed to `bindInstantiate` is kept (an ARC retain) for the
//! life of the instance and released by `bindClose`, as on the managed
//! targets (D229).
//!
//! Internal: only Std.PluginWasm should import this.
@axiom("lyric_wasmhost (lyric-rt/src/lyric_wasmhost.c) conforms to its contract in lyric_wasmhost.h: ids are positive, strings it returns come from lyric_wasmhost_alloc, and it returns the userdata it was given from lyric_wasmhost_close")
@io
package Std.PluginWasmBind

import Std.Core

extern func lwhAvailable(): Int = "lyric_wasmhost_available"

extern func lwhUnavailableReason(): NativePtr[Byte] = "lyric_wasmhost_unavailable_reason"

extern func lwhLastError(): NativePtr[Byte] = "lyric_wasmhost_last_error"

extern func lwhLoad(path: NativePtr[Byte]): Long = "lyric_wasmhost_load"

extern func lwhUnload(component: Long): Unit = "lyric_wasmhost_unload"

extern func lwhInstantiate(component: Long, maxMemoryBytes: Long, timeoutMs: Int, serve: (NativeUserdata, NativePtr[Byte], NativePtr[Byte], NativePtr[Byte]) -> NativePtr[Byte], userdata: NativeUserdata): Long = "lyric_wasmhost_instantiate"

extern func lwhCall(instance: Long, name: NativePtr[Byte], params: NativePtr[Byte], timeoutMs: Int): NativePtr[Byte] = "lyric_wasmhost_call"

extern func lwhHasExport(instance: Long, name: NativePtr[Byte]): Int = "lyric_wasmhost_has_export"

extern func lwhClose(instance: Long): NativePtr[Byte] = "lyric_wasmhost_close"

extern func lwhAlloc(size: Long): NativePtr[Byte] = "lyric_wasmhost_alloc"

extern func lwhFree(p: NativePtr[Byte]): Unit = "lyric_wasmhost_free"

pub func bindAvailable(): Int {
  lwhAvailable()
}

@unsafe_ffi
pub func bindUnavailableReason(): NativePtr[Byte] {
  lwhUnavailableReason()
}

@unsafe_ffi
pub func bindLastError(): NativePtr[Byte] {
  lwhLastError()
}

@unsafe_ffi
pub func bindLoad(path: in NativePtr[Byte]): Long {
  lwhLoad(path)
}

pub func bindUnload(component: in Long): Unit {
  lwhUnload(component)
}

/// Instantiate `component`, serving its imports with `serve`.  The closure is
/// kept for the life of the instance and released by `bindClose`, or here
/// when instantiation fails.
@unsafe_ffi
pub func bindInstantiate(
  component: in Long,
  maxMemoryBytes: in Long,
  timeoutMs: in Int,
  serve: in (NativePtr[Byte], NativePtr[Byte], NativePtr[Byte]) -> NativePtr[Byte],
): Long {
  val kept = nativeKeepCallback(serve)
  val id = lwhInstantiate(component, maxMemoryBytes, timeoutMs, serve, kept)
  if id <= 0i64 {
    nativeReleaseCallback(kept)
  }
  id
}

@unsafe_ffi
pub func bindCall(
  instance: in Long, name: in NativePtr[Byte], params: in NativePtr[Byte], timeoutMs: in Int
): NativePtr[Byte] {
  lwhCall(instance, name, params, timeoutMs)
}

@unsafe_ffi
pub func bindHasExport(instance: in Long, name: in NativePtr[Byte]): Int {
  lwhHasExport(instance, name)
}

/// Close `instance` and release the closure `bindInstantiate` kept for it.
@unsafe_ffi
pub func bindClose(instance: in Long): Unit {
  val kept = lwhClose(instance)
  if kept != nativeNullPtr() {
    nativeReleaseCallback(kept)
  }
}

@unsafe_ffi
pub func bindAlloc(size: in Long): NativePtr[Byte] {
  lwhAlloc(size)
}

@unsafe_ffi
pub func bindFree(p: in NativePtr[Byte]): Unit {
  lwhFree(p)
}
