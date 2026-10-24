//! std/_kernel_jvm/plugin_trusted_host.l - JVM twin of
//! `_kernel/plugin_trusted_host.l`: loading a trusted plugin's jar into the
//! host's process (docs/69 §10, D229).
//!
//! The jar gets its own `URLClassLoader` whose parent is the loader of the
//! host's stdlib.  Class loading delegates to the parent first, so every
//! class the host has (the `Std.*` packages, and an API package the host
//! and the plugin share) is the host's: the plugin's
//! `Std.Plugin.PluginServer` is the host's type, and the server its entry
//! point offers lands in the host's `Std.Plugin`.  The plugin's own packages
//! come from its jar; a plugin package whose name the host also uses would
//! resolve to the host's class, so such a plugin is refused.
//!
//! The entry point is found by name only: the jar manifest's `Main-Class`
//! (the plugin package's class, which holds the generated `main`) and its
//! public static `lyricPluginEntryV1`.  Nothing else of the plugin is
//! inspected.  The loader is never closed: trusted mode never unloads a
//! plugin (docs/69 Q-PLG-009).
@axiom("java.net.URLClassLoader, java.util.jar.JarFile, java.lang.reflect.Method and java.util.concurrent.locks.ReentrantLock conform to their documented JVM contracts")
@io
@unsafe_ffi
package Std.PluginTrustedHost

import Std.Core
import Std.Collections
import Std.Plugin

extern type JFile = "java.io.File"

extern type JUrl = "java.net.URL"

extern type JUrlClassLoader = "java.net.URLClassLoader"

extern type JClass = "java.lang.Class"

extern type JMethod = "java.lang.reflect.Method"

extern type JObject = "java.lang.Object"

extern type JObjects = "java.util.Objects"

extern type JJarFile = "java.util.jar.JarFile"

extern type JReentrantLock = "java.util.concurrent.locks.ReentrantLock"

extern type JSystem = "java.lang.System"

/// A plugin jar loaded by its own class loader, with its entry point.
pub record TrustedHostLibrary {
  path: String
  entryPoint: JMethod
}

// Held while an entry point runs and its offer is taken, so two threads
// loading plugins at once never take each other's server.
val trustedLoadGate: JReentrantLock = JReentrantLock.new()

// The entry point `Lyric.PluginExpand` generates (its `trustedEntryName`).
val trustedEntryMethodName: String = "lyricPluginEntryV1"

// A class every host that loads plugins has: `Std.Plugin`'s package class.
val sharedAnchorClass: String = "Std.Plugin"

/// The runtime whose trusted payloads this host loads.
pub func trustedHostRuntime(): String {
  "jvm"
}

/// Why this process cannot load a plugin jar, or `""` when it can.
pub func trustedHostUnavailableReason(): String {
  val imageCode = JSystem.getProperty("org.graalvm.nativeimage.imagecode") ?? ""
  if imageCode.length > 0 {
    "this host is a GraalVM native image, which cannot load a plugin jar; run the plugin in process or wasm mode, " +
      "or host it from the jar"
  } else {
    ""
  }
}

/// Open the plugin jar at `path` (absolute) with a new class loader and find
/// its entry point.  Runs none of the plugin's code.
pub func trustedHostOpen(path: in String): Result[TrustedHostLibrary, String] {
  try {
    val jar = JJarFile.new(path)
    val mainClass = jar.getManifest().getMainAttributes().getValue("Main-Class") ?? ""
    jar.close()
    if mainClass.length == 0 {
      return Err(error = path + " has no Main-Class; a trusted plugin jar is built from a @plugin record")
    }
    val urls: slice[JUrl] = [JFile.new(path).toURI().toURL()]
    val parent = JClass.forName(sharedAnchorClass).getClassLoader()
    val loader = JUrlClassLoader.new(urls, parent)
    val owner = JClass.forName(mainClass, false, loader)
    if not JObjects.equals(externAsObject(owner.getClassLoader()), externAsObject(loader)) {
      return Err(
        error = "the plugin's package class " + mainClass +
          " is also a class of this host; a trusted plugin's packages must be its own"
      )
    }
    val noTypes: slice[JClass] = []
    val entryPoint = owner.getMethod(trustedEntryMethodName, noTypes)
    Ok(value = TrustedHostLibrary(path = path, entryPoint = entryPoint))
  } catch Bug as b {
    Err(
      error = "cannot load " + path + " as a trusted plugin (a jar built from a @plugin record, with its " +
        trustedEntryMethodName +
        " entry point): " +
        b.message
    )
  }
}

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
  val noArgs: slice[JObject] = []
  trustedLoadGate.lock()
  var outcome: Result[PluginServer, String] = Err(
    error = "the entry point of " + library.path +
      " offered no server to this host; a plugin built by another Lyric release than the host cannot be loaded in process"
  )
  try {
    val _ = takeOfferedPluginServer()
    val _ = library.entryPoint.invoke(externAsObject(library.entryPoint), noArgs)
    match takeOfferedPluginServer() {
      case Some(server) -> {
        outcome = Ok(value = server)
      }
      case None -> ()
    }
  } catch Bug as b {
    outcome = Err(error = "the entry point of " + library.path + " failed: " + b.message)
  }
  trustedLoadGate.unlock()
  outcome
}
