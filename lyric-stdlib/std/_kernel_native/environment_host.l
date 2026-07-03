//! std/_kernel_native/environment_host.l — native-target process-state
//! boundary.
//!
//! The `--target native` twin of `_kernel/environment_host.l`, selected
//! by the native source loader by basename.  Implements the
//! exception-free Option seam (issue #4752) that `Std.Environment`
//! delegates to, over the audited lyric-rt helpers (`lyric_env_*`).
//!
//! Scope: variable get/set, the current working directory, and the
//! command-line arguments (`slice[String]` rides the shared list repr,
//! D-N-015).  `hostExit` (needs the `Never` return lowering) and the
//! .NET-specific probes (`hostAppBaseDirectory`,
//! `hostRuntimeDirectory`, `hostRuntimeIdentifier`) are not available
//! on the native target yet (issue #4752); the `Std.Environment`
//! functions built on them stay compile-time-unreachable on native
//! until then.
@axiom("POSIX environment calls via lyric-rt conform to their documented contracts")
package Std.EnvironmentHost

import Std.Core

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func rtEnvGetOk(name: NativePtr[Byte], outp: NativePtr[String]): Int = "lyric_env_get_ok"

extern func rtEnvSet(name: NativePtr[Byte], value: NativePtr[Byte]): Int = "lyric_env_set"

extern func rtEnvCwdOk(outp: NativePtr[String]): Int = "lyric_env_cwd_ok"

// Fresh owned list of the argv strings captured by the synthesised C
// main (lyric_args_set); the shared list repr IS the slice repr on
// this target (D-N-015).
extern func rtArgsGet(): slice[String] = "lyric_args_get"

@unsafe_ffi
pub func hostGetVarOpt(key: in String): Option[String] {
  var value: String = ""
  val c = toC(key)
  val rc = rtEnvGetOk(c, nativeAddrOf(value))
  freeC(c)
  if rc == 0 {
    Some(value = value)
  } else {
    None
  }
}

@unsafe_ffi
pub func hostSetEnvironmentVariable(key: in String, value: in String): Unit {
  // setenv(3) failures (EINVAL on an empty or '='-containing name,
  // ENOMEM) are absorbed to keep the managed twin's Unit surface; the
  // JVM twin is a documented no-op for the same reason.
  val ck = toC(key)
  val cv = toC(value)
  val _ignored = rtEnvSet(ck, cv)
  freeC(cv)
  freeC(ck)
}

@unsafe_ffi
pub func hostCurrentDirectory(): String {
  var cwd: String = ""
  val rc = rtEnvCwdOk(nativeAddrOf(cwd))
  if rc == 0 {
    cwd
  } else {
    // getcwd(3) only fails environmentally (unlinked cwd, allocation
    // failure); the managed twin throws there too, so panicking is the
    // parity behaviour.
    panic("Std.EnvironmentHost: cannot determine the current working directory")
  }
}

pub func hostGetCommandLineArgs(): slice[String] {
  rtArgsGet()
}
