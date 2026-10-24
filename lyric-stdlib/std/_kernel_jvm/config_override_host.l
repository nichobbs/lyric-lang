//! std/_kernel_jvm/config_override_host.l - JVM twin of
//! `_kernel/config_override_host.l` (D230).
//!
//! The store is the JVM system-property table (`System.setProperty` /
//! `getProperty`), keyed by the `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>` name.
//! System properties are not part of the environment a child process
//! inherits and are not listed by environment dumps.  The `<clinit>` the
//! compiler emits for a `config { }` block reads the same table through
//! `System.getProperty` before the `Std.Environment.setVar` overlay and the
//! real environment (`Jvm.Lowering.lowerConfigBlock`), so this file and that
//! function form the whole seam.  An empty value is no override, which is how
//! a registration is cleared.
@axiom("java.lang.System.setProperty and getProperty conform to their documented JVM contracts")
@io
package Std.ConfigOverrideHost

import Std.Core

extern type JCoSystem = "java.lang.System"

/// True: this target's config initialisers consult the override store.
pub func hostConfigOverrideSupported(): Bool {
  true
}

/// Register `value` for `key`.  Seen by every config block initialised
/// afterwards; an empty `value` clears the registration.
pub func hostSetConfigOverride(key: in String, value: in String): Unit {
  val _ = JCoSystem.setProperty(key, value)
}

/// The non-empty value registered for `key`, if any.
pub func hostGetConfigOverride(key: in String): Option[String] {
  val v = JCoSystem.getProperty(key) ?? ""
  if v.length == 0 {
    None
  } else {
    Some(value = v)
  }
}
