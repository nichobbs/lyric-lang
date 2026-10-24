//! std/plugin_wasm.l - Std.PluginWasm: the in-process wasm runtime for
//! `Std.Plugin`'s component mode (docs/69 §9.3), on dotnet, JVM and native
//! hosts.
//!
//! A host opts in by giving its `PluginHostConfig` this runtime:
//!
//! ```lyric
//! import Std.Plugin
//! import Std.PluginWasm
//!
//! val host = newPluginHost(PluginHostConfig(
//!   points = [...], providers = [...], policy = myPolicy,
//!   componentRuntime = Some(value = inProcessWasmRuntime()),
//! ))
//! ```
//!
//! Plugins with a `component` payload then run inside the host's process,
//! under the wasmtime C API: each in its own store whose linear memory is
//! capped at `wasmMaxMemoryBytes`, with a WASI p2 context that grants nothing
//! but an inherited stderr, its capability imports served from its grants,
//! and every call bounded by `callTimeoutMs` through epoch interruption, so a
//! plugin stuck in a loop is stopped rather than left running.
//!
//! `Std.Plugin` does not import this module: the compiler itself hosts
//! generator plugins with `Std.Plugin`, and must not depend on the C
//! embedding.  The embedding is `lyric-rt/src/lyric_wasmhost.c`: on dotnet
//! and the JVM the shared library `liblyric_wasmhost` (from
//! `$LYRIC_WASMHOST_LIB`, or the runtime's library search: next to the
//! program or `Lyric.Stdlib.dll` on .NET, the loader path on both), on native
//! part of `lyric_rt.a`.  It loads libwasmtime 49 at run time from
//! `$LYRIC_WASMTIME_LIB`, next to itself, or the loader path.
//! `hasInProcessWasm` reports whether all of that is present; when it is not,
//! component payloads are skipped and the other payloads run as before.
@io
package Std.PluginWasm

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Ffi
import Std.Environment as Env
import Std.PanicGuardHost
import Std.Plugin
import Std.PluginWasmBind
import Std.PluginWasmLoad

// Calls `bindAvailable`, which on dotnet and the JVM throws when the library
// itself cannot be found.
record AvailabilityProbe {
  var available: Bool
}

impl BugGuarded for AvailabilityProbe {
  func invoke(): Unit {
    self.available = bindAvailable() == 1
  }
}

// The shim's strings are its own allocations; read one and release it.
@unsafe_ffi
func takeShimString(p: in NativePtr[Byte]): String {
  if p == nativeNullPtr() {
    return ""
  }
  val s = unwrapOr(tryFromCString(p), "")
  bindFree(p)
  s
}

// A NUL-terminated copy of `s` in the shim's allocator, for a string the
// shim releases (an import's answer).
@unsafe_ffi
func shimString(s: in String): NativePtr[Byte] {
  val bytes = encodeUtf8(s)
  val n = bytes.length
  val p = bindAlloc(n.toLong() + 1i64)
  if p == nativeNullPtr() {
    return p
  }
  var i = 0
  while i < n {
    nativeStoreByte(p, i.toLong(), bytes[i])
    i += 1
  }
  nativeStoreByte(p, n.toLong(), 0u8)
  p
}

// Loads `$LYRIC_WASMHOST_LIB` when it is set; the reason it could not be.
func preloadExplicit(): Option[String] {
  val path = Env.getVarOrDefault("LYRIC_WASMHOST_LIB", "")
  if path.length == 0 {
    return None
  }
  match loadWasmHostLibrary(path) {
    case Ok(_) -> None
    case Err(e) -> Some(value = "$LYRIC_WASMHOST_LIB names '" + path + "', which could not be loaded: " + e)
  }
}

/// Whether components can be hosted in this process: the embedding's library
/// loads and finds libwasmtime 49.
@experimental
pub func hasInProcessWasm(): Bool {
  if isSome(preloadExplicit()) {
    return false
  }
  val probe = AvailabilityProbe(available = false)
  runCatchingBug(probe) and probe.available
}

/// Why `hasInProcessWasm()` is false, for a host's diagnostics ("" when it
/// is true).
@unsafe_ffi
@experimental
pub func inProcessWasmUnavailableReason(): String {
  match preloadExplicit() {
    case Some(why) -> return why
    case None -> ()
  }
  val probe = AvailabilityProbe(available = false)
  if not runCatchingBug(probe) {
    return "the in-process wasm library (liblyric_wasmhost) was not found: set $LYRIC_WASMHOST_LIB, or put it next to the program or on the library path"
  }
  takeShimString(bindUnavailableReason())
}

// Runs one import for the shim: the C strings in, the host's answer out in
// the shim's allocator.  A failure answers null, which traps the component
// instead of unwinding through C (D229).
@unsafe_ffi
func serveImport(
  imports: in ComponentImports,
  instance: in NativePtr[Byte],
  function: in NativePtr[Byte],
  params: in NativePtr[Byte],
): NativePtr[Byte] {
  val call = ImportCall(
    imports = imports,
    instance = unwrapOr(tryFromCString(instance), ""),
    function = unwrapOr(tryFromCString(function), ""),
    params = unwrapOr(tryFromCString(params), "{}"),
    answer = None
  )
  if not runCatchingBug(call) {
    return nativeNullPtr()
  }
  match call.answer {
    case Some(a) -> shimString(a)
    case None -> nativeNullPtr()
  }
}

record ImportCall {
  imports: ComponentImports
  instance: String
  function: String
  params: String
  var answer: Option[String]
}

impl BugGuarded for ImportCall {
  func invoke(): Unit {
    self.answer = Some(value = self.imports.serve(self.instance, self.function, self.params))
  }
}

@unsafe_ffi
func runtimeLoad(path: in String): Result[Long, String] {
  val cpath = toCString(path)
  val id = bindLoad(cpath)
  release(cpath)
  if id > 0i64 {
    Ok(value = id)
  } else {
    Err(error = takeShimString(bindLastError()))
  }
}

@unsafe_ffi
func runtimeInstantiate(
  component: in Long, maxMemoryBytes: in Long, timeoutMs: in Int, imports: in ComponentImports
): Result[Long, ComponentStartFailure] {
  val serve: (NativePtr[Byte], NativePtr[Byte], NativePtr[Byte]) -> NativePtr[Byte] = { instance: NativePtr[Byte], function: NativePtr[Byte], params: NativePtr[Byte] ->
    serveImport(imports, instance, function, params)
  }
  val id = bindInstantiate(component, maxMemoryBytes, timeoutMs, serve)
  if id > 0i64 {
    return Ok(value = id)
  }
  val message = takeShimString(bindLastError())
  if id == -2i64 {
    Err(error = ComponentStartTrapped(message = message))
  } else if id == -3i64 {
    Err(error = ComponentStartTimedOut(message = message))
  } else {
    Err(error = ComponentLinkFailed(message = message))
  }
}

@unsafe_ffi
func runtimeCall(instance: in Long, name: in String, paramsJson: in String, timeoutMs: in Int): String {
  val cname = toCString(name)
  val cparams = toCString(paramsJson)
  val envelope = takeShimString(bindCall(instance, cname, cparams, timeoutMs))
  release(cname)
  release(cparams)
  envelope
}

@unsafe_ffi
func runtimeHasExport(instance: in Long, name: in String): Bool {
  val cname = toCString(name)
  val has = bindHasExport(instance, cname) == 1
  release(cname)
  has
}

@unsafe_ffi
func runtimeClose(instance: in Long): Unit {
  bindClose(instance)
}

/// The wasmtime-backed `ComponentRuntime`.
record WasmtimeComponentRuntime {
}

impl ComponentRuntime for WasmtimeComponentRuntime {
  func available(): Bool {
    hasInProcessWasm()
  }

  func unavailableReason(): String {
    inProcessWasmUnavailableReason()
  }

  func load(path: in String): Result[Long, String] {
    runtimeLoad(path)
  }

  func unload(component: in Long): Unit {
    bindUnload(component)
  }

  func instantiate(
    component: in Long, maxMemoryBytes: in Long, timeoutMs: in Int, imports: in ComponentImports
  ): Result[Long, ComponentStartFailure] {
    runtimeInstantiate(component, maxMemoryBytes, timeoutMs, imports)
  }

  func callExport(instance: in Long, name: in String, paramsJson: in String, timeoutMs: in Int): String {
    runtimeCall(instance, name, paramsJson, timeoutMs)
  }

  func hasExport(instance: in Long, name: in String): Bool {
    runtimeHasExport(instance, name)
  }

  func close(instance: in Long): Unit {
    runtimeClose(instance)
  }
}

/// The in-process wasm runtime, for `PluginHostConfig.componentRuntime`.
/// Giving it to a host on a machine without the embedding is harmless: the
/// host asks `available()` and skips component payloads.
@experimental
pub func inProcessWasmRuntime(): ComponentRuntime {
  WasmtimeComponentRuntime()
}
