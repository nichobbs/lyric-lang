//! std/_kernel/plugin_host.l - platform identity for `Std.Plugin`'s payload
//! selection (D207 Decision 5).
//!
//! A plugin directory may ship one native executable per operating system
//! and processor architecture, named with the manifest's vocabulary
//! (`linux`/`macos`/`windows`, `x86_64`/`aarch64`).  This kernel reports the
//! running host in that vocabulary.  On .NET both values come from
//! `System.OperatingSystem` and `System.Runtime.InteropServices.RuntimeInformation`.
@axiom("System.Runtime.InteropServices.RuntimeInformation and System.OperatingSystem conform to their documented .NET contracts")
@io
package Std.PluginHost

import Std.Core

extern type NetPluginOs = "System.OperatingSystem"

extern type NetPluginRuntimeInfo = "System.Runtime.InteropServices.RuntimeInformation"

/// The host operating system: `"linux"`, `"macos"`, `"windows"`, or
/// `"other"`.
pub func hostPluginOs(): String {
  if NetPluginOs.IsWindows() {
    "windows"
  } else if NetPluginOs.IsMacOS() {
    "macos"
  } else if NetPluginOs.IsLinux() {
    "linux"
  } else {
    "other"
  }
}

/// The processor architecture: `"x86_64"`, `"aarch64"`, or `"other"`.
/// Read from the architecture suffix of `RuntimeInformation.RuntimeIdentifier`
/// (`linux-x64`, `osx-arm64`, `linux-musl-arm64`, ...), which names the
/// process architecture.
pub func hostPluginArch(): String {
  val rid: String = NetPluginRuntimeInfo.RuntimeIdentifier
  if rid.endsWith("-x64") {
    "x86_64"
  } else if rid.endsWith("-arm64") {
    "aarch64"
  } else {
    "other"
  }
}

/// The runtime the host program itself runs on.
pub func hostPluginRuntime(): String {
  "dotnet"
}
