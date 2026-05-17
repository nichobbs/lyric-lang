/// Flags.Aspects — pub aspect templates for feature-flag-gated execution.
///
/// Two templates:
///
///   FlagGated   — B-mode: short-circuits execution when a named flag is
///                 disabled.  Uses the process-global registry maintained by
///                 `Flags.Kernel.Net.checkFlag` so that no store reference is
///                 needed in the aspect config.  Register flags in the global
///                 registry with `Flags.Kernel.Net.registerBoolFlag` at startup.
///
///   FlagVariant — B-mode: proceeds unconditionally; compares the current
///                 String value of a named flag against a configured variant
///                 string.  Intended as a stub for future A/B variant routing.
///
/// Typical consumer usage:
///
///   import Flags.Aspects
///
///   aspect NewCheckout from Flags.Aspects.FlagGated {
///     matches: name like "handleCheckout*"
///     config { flagName: String = "new-checkout"; defaultOnMissing: Bool = false }
///   }
///
/// See docs/26-aspects.md §18 and lyric-feature-flags/README.md.

@runtime_checked
package Flags.Aspects

import Std.Core
import Flags
import Flags.Kernel.Net

// ─── FlagGated ────────────────────────────────────────────────────────────────

/// Short-circuit execution of the matched function when a named flag is disabled.
///
/// B-mode: the flag name is a scalar config field.  The flag value is read from
/// the process-global registry via `Flags.Kernel.Net.checkFlag`, which is backed
/// by `System.Collections.Concurrent`.  Register flags in the global registry at
/// application startup with `Flags.Kernel.Net.registerBoolFlag(name, value)`.
///
/// When the flag is disabled (or absent and `defaultOnMissing = false`) the aspect
/// returns `Err("feature disabled: " + flagName)` without invoking the handler.
/// When the flag is enabled (or absent and `defaultOnMissing = true`) the handler
/// is called normally.
///
/// **Type constraint:** apply only to handlers returning `Result[T, String]`.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled          Bool   — master switch; when false the handler always runs (default: true)
///   flagName         String — name of the flag to check (required; no default)
///   defaultOnMissing Bool   — value to use when the flag is absent from the registry (default: false)
@stable(since="0.1")
pub aspect FlagGated {
  config {
    enabled:          Bool   = true
    flagName:         String
    defaultOnMissing: Bool   = false
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val flagEnabled = Flags.Kernel.Net.checkFlag(flagName, defaultOnMissing)
      if flagEnabled {
        ret = call.proceed()
      } else {
        ret = Err("feature disabled: " + flagName)
      }
    }
  }
}

// ─── FlagVariant ──────────────────────────────────────────────────────────────

/// Stub aspect template for A/B variant routing.
///
/// B-mode: always proceeds unconditionally.  Full variant-specific routing
/// (read `flagName` from the registry, compare to `variant`, short-circuit
/// when the variant does not match) is deferred to a follow-up stage.
/// Marked `@experimental`; do not depend on the current stub behaviour.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled   Bool   — master switch (default: true)
///   flagName  String — name of the String flag (required; no default)
///   variant   String — expected variant value (required; no default)
@experimental
pub aspect FlagVariant {
  config {
    enabled:  Bool   = true
    flagName: String
    variant:  String
  }

  around(call) -> ret {
    // Stub: always proceeds. Variant-specific routing is deferred to a follow-up stage.
    ret = call.proceed()
  }
}
