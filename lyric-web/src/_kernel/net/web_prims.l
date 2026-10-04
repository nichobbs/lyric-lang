@cfg(feature = "dotnet")
@io
package Web.Kernel.Runtime

import Std.Console
import Std.Core
import Std.Collections
import Std.HttpServer
import Std.Environment as Env
import Web

// ─── Crash isolation (#5261, #6222, #6935) ──────────────────────────────────
// A failure in one request, one worker tick or the accept call must not stop
// the process silently. These are per-target because `try/catch` is: native has
// no unwinding (D-N-003), so `_kernel/native/web_prims.l` runs each call
// directly and a panic ends the process.

/// Run `job`; on a `Bug`, report it and make a best-effort 500 response.
func runJobGuarded(job: in Web.RequestJob): Unit {
  try {
    job.run()
  } catch Bug as e {
    job.fail(e.message)
    // The recovery write can itself throw when the failure correlates with a
    // broken connection; keep it request-local.
    try {
      job.recover()
    } catch Bug as e2 {
      Console.error("[lyric-web] failed to write the 500 response: " + e2.message)
    }
  }
}

/// One worker tick; a failing tick is logged and the loop carries on.
func tickGuarded(worker: in Web.Worker): Unit {
  try {
    worker.tick()
  } catch Bug as e {
    Console.error("[lyric-web] worker tick failed: " + e.message)
  }
}

/// The next request, or `None` after a listener failure: it is logged, the
/// listener stopped and the exit code set to 1.
pub func acceptNext(listener: in HttpListener, label: in String): Option[HttpContext] {
  try {
    Some(value = nextContext(listener))
  } catch Bug as e {
    Console.error("[lyric-web] listener failed on " + label + ": " + e.message)
    stopListener(listener)
    Env.exitCode(1)
    None
  }
}
