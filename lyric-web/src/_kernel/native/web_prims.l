@cfg(feature = "native")
@io
package Web.Kernel.Runtime

import Std.Console
import Std.Core
import Std.Collections
import Web

// ─── Crash isolation ─────────────────────────────────────────────────────────
// Native has no unwinding (D-N-003): a panic ends the process, so there is no
// failure to catch and each call runs directly. The dotnet twin
// (`_kernel/net/web_prims.l`) isolates request, tick and accept failures.
/// Run `job`. (`fail` and `recover` are never reached: nothing is caught.)
func runJobGuarded(job: in Web.RequestJob): Unit {
  job.run()
}

func tickGuarded(worker: in Web.Worker): Unit {
  worker.tick()
}

pub func runAcceptStep(loop: in Web.AcceptLoop): Unit {
  loop.step()
}

// ─── Canonical paths ─────────────────────────────────────────────────────────
@axiom("lyric_path_real_ok (lyric-rt/src/lyric_fs.c, realpath(3); lyric_fs_win32.c, GetFinalPathNameByHandleW) sets *out only when it returns 0, and lyric_string_to_cstring / lyric_cstring_free conform to their documented contracts")
extern func rtPathRealOk(path: NativePtr[Byte], outp: NativePtr[String]): Int = "lyric_path_real_ok"

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

/// How `realPath` ended.
pub union RealPathResult {
  /// The canonical absolute path, every link resolved.
  case Resolved(path: String)
  /// The path, or a link along it, names nothing.
  case Missing
  /// It could not be resolved for any other reason (a link loop, permissions).
  case Unresolvable
}

/// `path` with every symbolic link resolved and no `.`/`..` segments
/// (`realpath(3)`), for the static-file root check.
@unsafe_ffi
pub func realPath(path: in String): RealPathResult {
  var resolved: String = ""
  val c = toC(path)
  val rc = rtPathRealOk(c, nativeAddrOf(resolved))
  freeC(c)
  if rc == 0 {
    RealPathResult.Resolved(path = resolved)
  } else if rc == -1 {
    RealPathResult.Missing
  } else {
    RealPathResult.Unresolvable
  }
}
