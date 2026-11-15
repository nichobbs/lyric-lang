//! Jobs.Kernel.Native — the clock, sleep and job-ID primitives `Jobs` needs on
//! `--target native`.
//!
//! Thin wrappers over Std.Time and Std.Uuid, like `Jobs.Kernel.Net`; no C
//! symbol is declared here.
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(target = "native")
@io
package Jobs.Kernel.Native

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
