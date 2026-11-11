//! Jobs.Kernel.Net — .NET kernel boundary for the clock, sleep and job-ID
//! primitives `Jobs` needs.
//!
//! Thin wrappers over Std.Time and Std.Uuid; no BCL extern is declared here.
//! The Hangfire and Quartz.NET scheduler stubs and the
//! ConcurrentDictionary-backed `NativeJobScheduler` kernel that once lived in
//! this file were removed (docs/71, D552): the in-tree reference backend is
//! the pure-Lyric `InProcessJobScheduler`.
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
//!
//! Only active when compiled with feature = "dotnet" (the default; #1444-style
//! target-kernel split with `Jobs.Kernel.Jvm`).
@cfg(feature = "dotnet")
@io
package Jobs.Kernel.Net

import Std.Core
import Std.Time
import Std.Uuid

pub func nowMs(): Long {
  return nowEpochMillis()
}

pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  sleepMillis(ms)
}

// Returns a hyphenated UUID string: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" (36 chars).
pub func generateId(): String {
  return uuidToString(newUuid())
}
