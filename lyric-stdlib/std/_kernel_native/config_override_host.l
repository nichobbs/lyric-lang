//! std/_kernel_native/config_override_host.l - native twin of
//! `_kernel/config_override_host.l` (D230).
//!
//! The native backend reads every `config { }` field before `main` runs
//! (`Std.ConfigHost`, #7435), so no registration made by the program could ever
//! be seen: the window the store needs, between startup and the block's first
//! access, does not exist.  The kernel says so through
//! `hostConfigOverrideSupported`, and `Std.ConfigOverride` turns it into an
//! `Unsupported` error instead of accepting a registration nothing will read.
@axiom("The native backend reads config blocks before main; the probe reports false")
@io
package Std.ConfigOverrideHost

import Std.Core

/// False: native config fields are read before `main` runs.
pub func hostConfigOverrideSupported(): Bool {
  false
}

/// Never reached: callers gate on `hostConfigOverrideSupported`.
pub func hostSetConfigOverride(key: in String, value: in String): Unit {
  ()
}

/// Always `None`: nothing can be registered on this target.
pub func hostGetConfigOverride(key: in String): Option[String] {
  None
}
