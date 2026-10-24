//! std/_kernel/plugin_wasm_load.l - loads the in-process wasm host's shared
//! library from an explicit path on .NET (docs/69 §9.3).
//!
//! `Std.PluginWasmBind` binds `@library("lyric_wasmhost")`, which the runtime
//! finds by name.  When `$LYRIC_WASMHOST_LIB` names the library instead, the
//! host loads that file first with `NativeLibrary.Load`; the binding's later
//! load by name then resolves to the already-loaded library (its soname is
//! `liblyric_wasmhost.so`).
//!
//! Internal: only Std.PluginWasm should import this.
@axiom("System.Runtime.InteropServices.NativeLibrary.Load conforms to its documented .NET contract")
@io
package Std.PluginWasmLoad

import Std.Core

@unsafe_ffi
@externStatic
@externTarget("System.Runtime.InteropServices.NativeLibrary.Load")
func netLoadLibrary(libraryPath: in String): NativePtr[Byte] = ()

/// Load the shared library at `path`.  `Err` with the runtime's reason when
/// it cannot be loaded.
pub func loadWasmHostLibrary(path: in String): Result[Unit, String] {
  try {
    val _ = netLoadLibrary(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = b.message)
  }
}
