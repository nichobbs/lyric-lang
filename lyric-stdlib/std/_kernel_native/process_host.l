//! std/_kernel_native/process_host.l — native-target inherited-stdio
//! process execution.
//!
//! The `--target native` twin of `_kernel/process_host.l`, selected by the
//! native source loader by basename.  Implements only the Result seam
//! `Std.Process.run` delegates to, over lyric-rt's
//! `lyric_process_run_inherited` (fork + execvp, never a shell: the argv
//! list is passed through verbatim with no quoting or word splitting).  The
//! managed twins' handle-level functions (`hostSpawn`, `hostWait`, ...) are
//! not part of the native surface; nothing compiled for native calls them.
@axiom("fork/execvp inherited-stdio process execution via lyric-rt conforms to its documented contract")
package Std.ProcessHost

import Std.Core
import Std.Collections
import Std.Errors

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func rtProcessRunInherited(path: NativePtr[Byte], args: NativePtr[Byte], outCode: NativePtr[Int]): Int = "lyric_process_run_inherited"

// Run `executable` with `args` on inherited stdio and wait for it.  A child
// that cannot be started (including an executable that is not found) is an
// `IoError`, matching the managed twins, where `Process.Start` throws.
@unsafe_ffi
pub func hostRunInheritedResult(executable: in String, args: in List[String]): Result[Int, IOError] {
  var code: Int = 0
  val c = toC(executable)
  val rc = rtProcessRunInherited(c, args, nativeAddrOf(code))
  freeC(c)
  if rc == 0 {
    Ok(value = code)
  } else {
    Err(error = IoError(path = executable, message = "the process could not be started"))
  }
}
