//! std/_kernel_native/plugin_wasm_load.l - the native twin of
//! `Std.PluginWasmLoad` (docs/69 §9.3).
//!
//! A native host links the in-process wasm host statically (`lyric_rt.a`), so
//! there is no shared library to load and `$LYRIC_WASMHOST_LIB` does not
//! apply; the shim itself loads libwasmtime at run time.
//!
//! Internal: only Std.PluginWasm should import this.
@io
package Std.PluginWasmLoad

import Std.Core

/// Nothing to load on native: the shim is part of the program.
pub func loadWasmHostLibrary(path: in String): Result[Unit, String] {
  Ok(value = ())
}
