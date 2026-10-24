//! std/_kernel_native/config_override_host.l - native twin of
//! `_kernel/config_override_host.l` (D230).
//!
//! The native backend has no lowering for `config { }` blocks yet (`N0025`,
//! #7435), so there is no initialiser that could consult an override store.
//! The kernel says so through `hostConfigOverrideSupported`, and
//! `Std.ConfigOverride` turns it into an `Unsupported` error instead of
//! accepting a registration nothing will ever read.  The native lowering and
//! this twin's real store are part of #7435.
@axiom("The native backend lowers no config blocks; the probe reports false")
@io
package Std.ConfigOverrideHost

import Std.Core

/// False: the native backend lowers no `config { }` blocks.
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
