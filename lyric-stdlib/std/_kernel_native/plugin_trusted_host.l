//! std/_kernel_native/plugin_trusted_host.l - native twin of
//! `_kernel/plugin_trusted_host.l`: loading a trusted plugin's shared library
//! into the host's process (docs/69 §10, D229).
//!
//! A trusted native plugin is a shared library built with `--shape plugin`.
//! It contains its own compiled copy of the Lyric code it uses but no
//! `lyric_rt`: its runtime symbols resolve against the host executable,
//! which a build that reaches this kernel links with its whole runtime
//! exported, so there is one heap, one ARC and one scheduler in the process.
//! The library exports two fixed, versioned C symbols:
//!
//! - `lyric_plugin_abi_v1` returns the fingerprint of the Lyric release and
//!   the boundary packages it was built with (`Std.Core`, `Std.JsonValue`,
//!   `Std.JsonRpc`, `Std.Plugin`).  Objects cross between the host's code and
//!   the plugin's directly, so both must lay them out alike; a library whose
//!   fingerprint differs from the host's (`lyric_plugin_host_abi_v1`, written
//!   into the host by the same build step) is refused.
//! - `lyric_plugin_entry_v1` returns a fresh `PluginServer` (the generated
//!   `lyricPluginServerV1()`), owned by the caller.
//!
//! Native has no unwinding (D-N-003): a panic in a trusted plugin ends the
//! host process.  Nothing is ever unloaded (docs/69 Q-PLG-009): `dlclose`
//! would free the code that the destructors of the plugin's objects run.
@axiom("dlopen/dlsym via lyric-rt conform to their documented POSIX contracts, and a library whose lyric_plugin_abi_v1 matches the host's lays out every boundary type as the host does")
@io
package Std.PluginTrustedHost

import Std.Core
import Std.Collections
import Std.Plugin

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func rtEnvOsKind(): Int = "lyric_env_os_kind"

extern func rtPluginOpen(path: NativePtr[Byte]): NativePtr[Byte] = "lyric_plugin_dl_open"

extern func rtPluginLastError(): String = "lyric_plugin_dl_error"

extern func rtPluginSym(handle: NativePtr[Byte], name: NativePtr[Byte]): NativePtr[Byte] = "lyric_plugin_dl_sym"

extern func rtPluginCallText(fn: NativePtr[Byte]): String = "lyric_plugin_call_text"

extern func rtPluginCallEntry(fn: NativePtr[Byte]): PluginServer = "lyric_plugin_call_entry"

extern func rtText(text: NativePtr[Byte]): String = "lyric_plugin_text"

// Written into a host that reaches this kernel by the native build
// (`Lyric.LlvmBridge`), from the same fingerprint `--shape plugin` writes
// into a plugin library.
extern func rtHostAbi(): NativePtr[Byte] = "lyric_plugin_host_abi_v1"

/// A plugin library opened in this process, with its entry point.
pub record TrustedHostLibrary {
  path: String
  entryPoint: NativePtr[Byte]
}

/// The runtime whose trusted payloads this host loads.
pub func trustedHostRuntime(): String {
  "native"
}

/// Why this process cannot load a plugin library, or `""` when it can.
pub func trustedHostUnavailableReason(): String {
  val os = rtEnvOsKind()
  if os == 1 or os == 2 {
    ""
  } else if os == 3 {
    "trusted native plugins are not supported on Windows, where a DLL cannot import the runtime from the host executable; run the plugin in process or wasm mode"
  } else {
    "trusted native plugins need a Linux or macOS host"
  }
}

func symbol(handle: in NativePtr[Byte], name: in String): NativePtr[Byte] {
  val c = toC(name)
  val p = rtPluginSym(handle, c)
  freeC(c)
  p
}

/// Open the plugin library at `path` (absolute), check its fingerprint
/// against the host's and find its entry point.  Runs none of the plugin's
/// Lyric code.
pub func trustedHostOpen(path: in String): Result[TrustedHostLibrary, String] {
  val c = toC(path)
  val handle = rtPluginOpen(c)
  freeC(c)
  if handle == nativeNullPtr() {
    return Err(error = "cannot load " + path + ": " + rtPluginLastError())
  }
  val abiFn = symbol(handle, "lyric_plugin_abi_v1")
  if abiFn == nativeNullPtr() {
    return Err(error = path + " exports no lyric_plugin_abi_v1; build the plugin with --shape plugin")
  }
  val entryPoint = symbol(handle, "lyric_plugin_entry_v1")
  if entryPoint == nativeNullPtr() {
    return Err(error = path + " exports no lyric_plugin_entry_v1; build the plugin with --shape plugin")
  }
  val pluginAbi = rtPluginCallText(abiFn)
  val hostAbi = rtText(rtHostAbi())
  if pluginAbi != hostAbi {
    return Err(
      error = path + " was built by another Lyric release or against another standard library than this host " +
        "(plugin ABI " +
        pluginAbi +
        ", host ABI " +
        hostAbi +
        "); rebuild the plugin with the host's compiler"
    )
  }
  Ok(value = TrustedHostLibrary(path = path, entryPoint = entryPoint))
}

/// The managed twins' rendezvous for a plugin's `lyricPluginEntryV1`.  A
/// native plugin library returns its server from `lyric_plugin_entry_v1`
/// instead, so there is nothing to hand over here.
pub func offerTrustedPluginServer(server: in PluginServer): Unit {
}

/// Call the library's entry point for a fresh server.
pub func trustedHostNewServer(library: in TrustedHostLibrary): Result[PluginServer, String] {
  Ok(value = rtPluginCallEntry(library.entryPoint))
}
