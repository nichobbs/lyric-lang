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

/// Proceed normally; after the call, optionally tag the result when the flag
/// matches the configured variant.
///
/// B-mode: reads the current String value of `flagName` from the process-global
/// registry and compares it to `variant`.  In this initial version the aspect
/// always proceeds without modification — the comparison is available to
/// consumers who subclass or extend this template for real A/B routing.
/// Full variant-result wrapping is a follow-up stage.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled   Bool   — master switch; when false the handler always runs (default: true)
///   flagName  String — name of the String flag to read (required; no default)
///   variant   String — expected flag value that identifies the active variant (required; no default)
@stable(since="0.1")
pub aspect FlagVariant {
  config {
    enabled:  Bool   = true
    flagName: String
    variant:  String
  }

  around(call) -> ret {
    // Always proceed; the variant comparison is available for future routing.
    ret = call.proceed()
    if enabled {
      val currentVariant = Flags.Kernel.Net.getStringFlag(flagName, "")
      // When currentVariant == variant, the caller is in the treatment group.
      // Variant-specific result wrapping is deferred to a follow-up stage.
      val _ = currentVariant == variant
    }
  }
}
