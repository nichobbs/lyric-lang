//! std/config_override.l - Std.ConfigOverride: set a `config { }` field's
//! value from code, before the block is first read (D230).
//!
//! A `config { }` block is initialised once, on its first access, from the
//! environment variable `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>`.  This module
//! registers a value that initialiser consults before the environment and
//! before the declared default, so a value fetched at startup (a secret, a
//! remote setting) reaches the block without ever being written to the
//! process environment: a registered value is not inherited by child
//! processes and does not show up in environment dumps.
//!
//! Ordering: the block reads the store exactly once, when it is first
//! accessed, so register before that access (normally the first statements of
//! `main`).  A value registered afterwards is not seen by that block.
//!
//! Precedence, highest first: this store, `Std.Environment.setVar`, the real
//! environment, the declared default.  An empty value counts as no override.
//!
//! Targets: .NET (the `AppDomain` data table) and JVM (system properties).
//! The native backend reads every `config { }` field before `main` runs
//! (#7435), so there is no point at which a registration could be seen; every
//! call reports `Unsupported` there.
//! `Unsupported` on native is the only case where a registration is not
//! effective: it is always reported, never silently dropped.
@runtime_checked
@io
package Std.ConfigOverride

import Std.Core
import Std.ConfigOverrideHost

/// Why a registration was refused.
@stable(since = "0.1")
pub union ConfigOverrideError {
  /// This target has no config-override store (native).  Retrying will never
  /// succeed.
  case Unsupported(reason: String)
  /// The key is not a `LYRIC_CONFIG_` name.  The store backs config blocks
  /// only; on the JVM an unchecked key would be an arbitrary system property.
  case InvalidKey(key: String)
  /// The value contains a NUL character, which no environment variable can
  /// hold either.
  case InvalidValue(key: String)
}

/// Human-readable message for logging.
@stable(since = "0.1")
pub func errorMessage(err: in ConfigOverrideError): String {
  match err {
    case Unsupported(reason) -> "config override unsupported: " + reason
    case InvalidKey(key) -> "config override key must start with LYRIC_CONFIG_: " + key
    case InvalidValue(key) -> "config override value for " + key + " contains a NUL character"
  }
}

/// The prefix every config override key carries.
@stable(since = "0.1")
@pure
pub func keyPrefix(): String = "LYRIC_CONFIG_"

/// True when this target consults the override store.
@stable(since = "0.1")
pub func isSupported(): Bool {
  hostConfigOverrideSupported()
}

func checkKey(key: in String): Result[Unit, ConfigOverrideError] {
  if not hostConfigOverrideSupported() {
    return Err(
      error = Unsupported(
        reason = "this target reads config blocks before main runs (native), so a registration would never be seen"
      )
    )
  }
  if not key.startsWith(keyPrefix()) or key.length == keyPrefix().length {
    return Err(error = InvalidKey(key = key))
  }
  Ok(value = ())
}

/// Register `value` for the config field whose environment variable name is
/// `key` (`AnnotatedField.envVar` from `Std.AnnotationMeta`, or the
/// `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>` name by hand).  An empty `value`
/// clears any registration.
///
/// # Errors
/// - `Unsupported`: the target reads config blocks before `main` (native).
/// - `InvalidKey`: `key` does not start with `LYRIC_CONFIG_`.
/// - `InvalidValue`: `value` contains a NUL character.
@stable(since = "0.1")
pub func setConfigOverride(key: in String, value: in String): Result[Unit, ConfigOverrideError] {
  match checkKey(key) {
    case Err(e) -> Err(error = e)
    case Ok(_) -> {
      if value.contains("\u{0000}") {
        return Err(error = InvalidValue(key = key))
      }
      hostSetConfigOverride(key, value)
      Ok(value = ())
    }
  }
}

/// Remove any registration for `key`; the block then reads the environment
/// and its default as usual.
///
/// # Errors
/// - `Unsupported`: the target reads config blocks before `main` (native).
/// - `InvalidKey`: `key` does not start with `LYRIC_CONFIG_`.
@stable(since = "0.1")
pub func clearConfigOverride(key: in String): Result[Unit, ConfigOverrideError] {
  match checkKey(key) {
    case Err(e) -> Err(error = e)
    case Ok(_) -> {
      hostSetConfigOverride(key, "")
      Ok(value = ())
    }
  }
}

/// The value registered for `key`, if any.  Always `None` on a target with
/// no store.
@stable(since = "0.1")
pub func getConfigOverride(key: in String): Option[String] {
  hostGetConfigOverride(key)
}
