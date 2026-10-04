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
