//! std/_kernel_native/plugin_host.l - native twin of
//! `_kernel/plugin_host.l`.
//!
//! The operating system and architecture of a native program are those of
//! the lyric-rt it was built against, so both come from compile-time
//! properties of the runtime (`lyric_env_os_kind`, `lyric_env_arch_kind`).
@axiom("lyric-rt platform probes report the target lyric-rt was compiled for")
@io
package Std.PluginHost

import Std.Core

extern func rtEnvOsKind(): Int = "lyric_env_os_kind"

extern func rtEnvArchKind(): Int = "lyric_env_arch_kind"

/// The host operating system: `"linux"`, `"macos"`, `"windows"`, or
/// `"other"`.
pub func hostPluginOs(): String {
  val k = rtEnvOsKind()
  if k == 1 {
    "linux"
  } else if k == 2 {
    "macos"
  } else if k == 3 {
    "windows"
  } else {
    "other"
  }
}

/// The processor architecture: `"x86_64"`, `"aarch64"`, or `"other"`.
pub func hostPluginArch(): String {
  val k = rtEnvArchKind()
  if k == 1 {
    "x86_64"
  } else if k == 2 {
    "aarch64"
  } else {
    "other"
  }
}

/// The runtime the host program itself runs on.
pub func hostPluginRuntime(): String {
  "native"
}
