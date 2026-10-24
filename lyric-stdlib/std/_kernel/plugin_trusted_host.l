//! std/_kernel/plugin_trusted_host.l - loading a trusted plugin's assembly
//! into the host's process on .NET (docs/69 §10, D231).
//!
//! The plugin assembly goes into its own `AssemblyLoadContext`.  The context
//! does not resolve `Lyric.Stdlib` itself, so the runtime falls back to the
//! default context and the plugin binds to the host's loaded copy: the
//! plugin's `Std.Plugin.PluginServer` is the host's type, and the server its
//! entry point offers lands in the host's `Std.Plugin`.  Every other
//! assembly beside the plugin (its own packages, its NuGet dependencies) is
//! loaded into the plugin's context first, so the plugin keeps its own
//! copies even when the host has assemblies of the same names.
//!
//! The entry point is found by name only: the assembly's declared entry
//! point (the generated `main`) names the plugin package's `Program` class,
//! and the kernel invokes that class's public static `lyricPluginEntryV1`.
//! Nothing else of the plugin is inspected.
//!
//! The context is not collectible: trusted mode never unloads a plugin
//! (docs/69 Q-PLG-009), and a collectible context would cost every type in
//! it for an unload that is never offered.
@axiom("System.Runtime.Loader.AssemblyLoadContext, System.Reflection and System.Threading.Monitor conform to their documented .NET contracts")
@io
@unsafe_ffi
package Std.PluginTrustedHost

import Std.Core
import Std.Collections
import Std.Plugin

extern type NetAssemblyLoadContext = "System.Runtime.Loader.AssemblyLoadContext"

extern type NetAssembly = "System.Reflection.Assembly"

extern type NetMethodInfo = "System.Reflection.MethodInfo"

extern type NetType = "System.Type"

extern type NetObject = "System.Object"

extern type NetMonitor = "System.Threading.Monitor"

extern type NetRuntimeFeature = "System.Runtime.CompilerServices.RuntimeFeature"

extern type NetDirectory = "System.IO.Directory"

extern type NetIoPath = "System.IO.Path"

/// A plugin assembly loaded into its own context, with its entry point.
pub record TrustedHostLibrary {
  path: String
  owner: NetType
  entryPoint: NetMethodInfo
}

// Held while an entry point runs and its offer is taken, so two threads
// loading plugins at once never take each other's server.
val trustedLoadGate: NetObject = NetObject.new()

/// The runtime whose trusted payloads this host loads.
pub func trustedHostRuntime(): String {
  "dotnet"
}

/// Why this process cannot load a plugin assembly, or `""` when it can.
pub func trustedHostUnavailableReason(): String {
  if NetRuntimeFeature.IsDynamicCodeSupported {
    ""
  } else {
    "this host is compiled ahead of time (Native AOT), which cannot load a plugin assembly; " +
      "run the plugin in process or wasm mode, or host it from a portable build"
  }
}

// The stdlib is the host's: a copy beside the plugin must not be loaded into
// the plugin's context, or the plugin's `Std.Plugin` types would not be the
// host's.
func isSharedAssemblyFile(file: in String): Bool {
  val name = NetIoPath.GetFileName(file)
  name.startsWith("Lyric.Stdlib")
}

/// Load the plugin assembly at `path` (absolute) into a new context and find
/// its entry point.  Runs none of the plugin's code.
pub func trustedHostOpen(path: in String): Result[TrustedHostLibrary, String] {
  try {
    val context = NetAssemblyLoadContext.new("lyric-plugin:" + path, false)
    val dir = NetIoPath.GetDirectoryName(path)
    for file in NetDirectory.GetFiles(dir, "*.dll") {
      if file != path and not isSharedAssemblyFile(file) {
        try {
          val _ = context.LoadFromAssemblyPath(file)
        } catch Bug as _ {
          // Not a managed assembly (a native library beside the plugin):
          // nothing for the context to load.
          ()
        }
      }
    }
    val assembly = context.LoadFromAssemblyPath(path)
    val main = assembly.EntryPoint
    val owner = main.DeclaringType
    val entryPoint = owner.GetMethod(trustedEntryMethodName)
    Ok(value = TrustedHostLibrary(path = path, owner = owner, entryPoint = entryPoint))
  } catch Bug as b {
    Err(
      error = "cannot load " + path + " as a trusted plugin (an assembly built from a @plugin record, with its " +
        trustedEntryMethodName +
        " entry point): " +
        b.message
    )
  }
}

// The entry point `Lyric.PluginExpand` generates (its `trustedEntryName`).
val trustedEntryMethodName: String = "lyricPluginEntryV1"

// The server a trusted plugin's generated entry point hands over (docs/69
// §10).  The host loads the plugin so that the plugin's stdlib is the
// host's own; `trustedHostNewServer` runs the plugin's `lyricPluginEntryV1`,
// which writes its server here, and takes it while it holds the load lock.
record TrustedOfferSlot {
  var offered: Option[PluginServer]
}

val trustedOfferSlot: TrustedOfferSlot = TrustedOfferSlot(offered = None)

/// Hand `server` to the host loading this plugin into its own process.
/// Called by the `lyricPluginEntryV1` entry point `Lyric.PluginExpand`
/// generates for a `@plugin` record; application code has no use for it.
pub func offerTrustedPluginServer(server: in PluginServer): Unit {
  var slot = trustedOfferSlot
  slot.offered = Some(value = server)
}

// Take the server the entry point offered, and forget it.
func takeOfferedPluginServer(): Option[PluginServer] {
  var slot = trustedOfferSlot
  val offered = slot.offered
  slot.offered = None
  offered
}

/// Run the library's entry point and take the server it offers.
pub func trustedHostNewServer(library: in TrustedHostLibrary): Result[PluginServer, String] {
  val noArgs: slice[NetObject] = []
  NetMonitor.Enter(trustedLoadGate)
  var outcome: Result[PluginServer, String] = Err(
    error = "the entry point of " + library.path +
      " offered no server to this host; a plugin built against another Lyric.Stdlib than the host's cannot " +
      "be loaded in process"
  )
  try {
    val _ = takeOfferedPluginServer()
    val _ = library.entryPoint.Invoke(externAsObject(library.owner), noArgs)
    match takeOfferedPluginServer() {
      case Some(server) -> {
        outcome = Ok(value = server)
      }
      case None -> ()
    }
  } catch Bug as b {
    outcome = Err(error = "the entry point of " + library.path + " failed: " + b.message)
  }
  NetMonitor.Exit(trustedLoadGate)
  outcome
}
