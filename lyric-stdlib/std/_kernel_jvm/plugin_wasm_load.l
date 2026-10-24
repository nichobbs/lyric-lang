//! std/_kernel_jvm/plugin_wasm_load.l - loads the in-process wasm host's
//! shared library from an explicit path on the JVM (docs/69 §9.3).
//!
//! `Std.PluginWasmBind` binds `@library("lyric_wasmhost")`, which the JVM
//! looks up by name with `SymbolLookup.libraryLookup` (D158).  When
//! `$LYRIC_WASMHOST_LIB` names the library instead, the host loads that file
//! first with `System.load`; the binding's later lookup by name then resolves
//! to the already-loaded library (its soname is `liblyric_wasmhost.so`).
//!
//! Internal: only Std.PluginWasm should import this.
@axiom("java.lang.System.load conforms to its documented JVM contract")
@io
package Std.PluginWasmLoad

import Std.Core

extern type JWasmLoadSystem = "java.lang.System"

/// Load the shared library at `path`.  `Err` with the JVM's reason when it
/// cannot be loaded.
pub func loadWasmHostLibrary(path: in String): Result[Unit, String] {
  try {
    JWasmLoadSystem.load(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = b.message)
  }
}
