//! std/_kernel/config_override_host.l - trusted host boundary for
//! `Std.ConfigOverride` (D230).
//!
//! The store is the .NET `AppDomain` data table (`SetData` / `GetData`): a
//! process-wide string-keyed table that is not the environment block, so a
//! registered value is never inherited by a child process and never listed by
//! tools that dump the environment.  The initialiser the compiler emits for a
//! `config { }` block reads it through the same two BCL members
//! (`Msil.Lowering.emitConfigLookupMsil`), so this file and that function form
//! the whole seam.  An empty value is no override, which is how a registration
//! is cleared.
@axiom("System.AppDomain.SetData and GetData conform to their documented .NET contracts")
@io
package Std.ConfigOverrideHost

import Std.Core

extern type NetCoDomain = "System.AppDomain"

// The BCL parameter is `object`; only strings are ever stored, and the
// initialiser reads the slot back with `isinst string`.
@externTarget("System.AppDomain.SetData")
func netSetData(d: in NetCoDomain, name: in String, value: in String): Unit = ()

@externTarget("System.AppDomain.GetData")
func netGetData(d: in NetCoDomain, name: in String): String? = ()

/// True: this target's config initialisers consult the override store.
pub func hostConfigOverrideSupported(): Bool {
  true
}

/// Register `value` for `key`.  Seen by every config block initialised
/// afterwards; an empty `value` clears the registration.
pub func hostSetConfigOverride(key: in String, value: in String): Unit {
  netSetData(NetCoDomain.CurrentDomain, key, value)
}

/// The non-empty value registered for `key`, if any.
pub func hostGetConfigOverride(key: in String): Option[String] {
  val v = netGetData(NetCoDomain.CurrentDomain, key) ?? ""
  if v.length == 0 {
    None
  } else {
    Some(value = v)
  }
}
