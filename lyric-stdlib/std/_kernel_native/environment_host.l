//! std/_kernel_native/environment_host.l — native-target process-state
//! boundary.
//!
//! The `--target native` twin of `_kernel/environment_host.l`, selected
//! by the native source loader by basename.  Implements the
//! exception-free Option seam (issue #4752) that `Std.Environment`
//! delegates to, over the audited lyric-rt helpers (`lyric_env_*`).
//!
//! Scope: variable get/set, the current working directory, the
//! command-line arguments (`slice[String]` rides the shared list repr,
//! D-N-015), and the two runtime-identity probes (below). Still
//! missing (issue #4752's residual-seam audit, D-progress-878):
//! `hostExit` (`extern func` with a `Never` return type has no native
//! codegen lowering at all — `Lyric.LlvmCodegen: this type form is not
//! yet supported for --target native (Phase N1)`, confirmed by direct
//! repro; a compiler gap this kernel cannot work around, filed as
//! issue #6901) and `hostAppBaseDirectory` (feasible via
//! `readlink("/proc/self/exe")` on Linux, but genuinely new `lyric-rt`
//! C surface, deliberately deferred rather than bundled into this
//! kernel-focused audit pass — `Std.Environment.appBaseDirectory`'s own
//! `@stable(since = "0.1")` marks it the oldest, least-used probe of
//! the four).
//!
//! `hostRuntimeDirectory`/`hostRuntimeIdentifier` both return `""`
//! unconditionally: `Std.Environment`'s own public doc comments already
//! document empty string as a VALID, anticipated value for a target
//! with no .NET-runtime-shared-framework concept — `runtimeDirectory`'s
//! own comment says "May return an empty string in native-AOT
//! scenarios", and `runtimeIdentifier`'s says the JVM twin already
//! returns `""` for the identical "no .NET RID equivalent here" reason.
//! Native is exactly that case, so this is a faithful implementation of
//! an already-specified contract, not an ad hoc shortcut.
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

/// See the module header: native has no .NET shared-framework concept,
/// so this always returns `""` — a value `Std.Environment
/// .runtimeDirectory`'s own doc comment already documents as valid for
/// exactly this case.
pub func hostRuntimeDirectory(): String {
  ""
}

/// See the module header: native has no .NET runtime identifier, so
/// this always returns `""` — the same "no equivalent here" contract
/// the JVM twin already documents for `Std.Environment
/// .runtimeIdentifier`.
pub func hostRuntimeIdentifier(): String {
  ""
}
