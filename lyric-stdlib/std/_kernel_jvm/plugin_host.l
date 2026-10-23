//! std/_kernel_jvm/plugin_host.l - JVM twin of `_kernel/plugin_host.l`.
//!
//! Reads the standard `os.name` and `os.arch` system properties and maps
//! them onto the manifest vocabulary of D207 Decision 5.
@axiom("java.lang.System.getProperty conforms to its documented JVM contract")
@io
package Std.PluginHost

import Std.Core

extern type JPluginSystem = "java.lang.System"

/// The host operating system: `"linux"`, `"macos"`, `"windows"`, or
/// `"other"`.
pub func hostPluginOs(): String {
  val name = JPluginSystem.getProperty("os.name") ?? ""
  if name.startsWith("Windows") {
    "windows"
  } else if name.startsWith("Mac") {
    "macos"
  } else if name.startsWith("Linux") {
    "linux"
  } else {
    "other"
  }
}

/// The processor architecture: `"x86_64"`, `"aarch64"`, or `"other"`.
/// The JDK reports `amd64` on Linux and Windows and `x86_64` on macOS.
pub func hostPluginArch(): String {
  val arch = JPluginSystem.getProperty("os.arch") ?? ""
  if arch == "amd64" or arch == "x86_64" {
    "x86_64"
  } else if arch == "aarch64" or arch == "arm64" {
    "aarch64"
  } else {
    "other"
  }
}

/// The runtime the host program itself runs on.
pub func hostPluginRuntime(): String {
  "jvm"
}
