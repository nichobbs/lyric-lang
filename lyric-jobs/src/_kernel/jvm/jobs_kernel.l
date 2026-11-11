//! Jobs.Kernel.Jvm — JVM kernel boundary for the clock, sleep and job-ID
//! primitives `Jobs` needs.
//!
//! The Quartz Scheduler binding that once lived in this file was removed
//! (docs/71, D552): it could only run a fixed no-op native command, never an
//! application handler, and CI never exercised it.  The in-tree reference
//! backend is the pure-Lyric `InProcessJobScheduler`.
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
//!
//! Only active when compiled with feature = "jvm".
@cfg(feature = "jvm")
@io
package Jobs.Kernel.Jvm

import Std.Core
import Std.Time
import Std.Uuid

extern type JThread = "java.lang.Thread"

pub func nowMs(): Long {
  return nowEpochMillis()
}

pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  JThread.sleep(ms.toLong())
}

pub func generateId(): String {
  return uuidToString(newUuid())
}
