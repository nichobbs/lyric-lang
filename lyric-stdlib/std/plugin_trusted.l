//! std/plugin_trusted.l - Std.Plugin.Trusted: loading trusted plugins into
//! the host's process (docs/69 §10, D231).
//!
//! A host enables trusted mode by giving its `PluginHostConfig` the loader
//! this package provides:
//!
//! ```lyric
//! val host = newPluginHost(PluginHostConfig(
//!   points = [editorExtensionPointInfo()],
//!   providers = providers,
//!   policy = myPolicy,                     // returns GrantDecision(trusted = true) for first-party plugins
//!   trustedLoader = Some(value = trustedPluginLoader()),
//! ))
//! ```
//!
//! A plugin then runs in the host's process only when the grant policy marks
//! it trusted and it ships a trusted payload for the host's runtime (a
//! dotnet assembly, a JVM jar, or a native shared library built with
//! `--shape plugin`); every other plugin runs in process or wasm mode as
//! before.  The plugin keeps its generated server, its capability clients and
//! its grants: calls go through the same dispatcher, guards and providers,
//! with direct calls in place of a pipe.
//!
//! The loader lives in its own package so a host that never loads plugins in
//! process does not link the loading code at all (a Native AOT host stays
//! free of `AssemblyLoadContext`, and a native host keeps its runtime
//! unexported).
@io
package Std.Plugin.Trusted

import Std.Core
import Std.Plugin
import Std.PluginTrustedHost

record HostTrustedLibrary {
  handle: TrustedHostLibrary
}

impl TrustedLibrary for HostTrustedLibrary {
  func newServer(): Result[PluginServer, String] {
    trustedHostNewServer(self.handle)
  }
}

record HostTrustedLoader {
}

impl TrustedLoader for HostTrustedLoader {
  func runtime(): String {
    trustedHostRuntime()
  }

  func unavailableReason(): String {
    trustedHostUnavailableReason()
  }

  func open(path: in String): Result[TrustedLibrary, String] {
    match trustedHostOpen(path) {
      case Ok(handle) -> {
        val library: TrustedLibrary = HostTrustedLibrary(handle = handle)
        Ok(value = library)
      }
      case Err(e) -> Err(error = e)
    }
  }
}

/// The loader for this host's runtime: dotnet assemblies on .NET, jars on
/// the JVM, shared libraries on native (Linux and macOS).  On a host that
/// cannot load code (Native AOT, a GraalVM native image, Windows or wasm32
/// native) its `unavailableReason()` says why, and the host runs every
/// plugin in process or wasm mode.
@experimental
pub func trustedPluginLoader(): TrustedLoader {
  HostTrustedLoader()
}
