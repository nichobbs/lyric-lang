//! Auth.Aspects — transport-agnostic authentication aspect templates.
//!
//! Provides reusable template aspects that delegate to lyric-auth verification
//! primitives (Auth.verifyApiKey, Auth.verifyJwt) without coupling to any
//! transport protocol.  Protocol-specific bindings live in the consuming library
//! (Web.Aspects.ApiKey for HTTP, Ws.Aspects.WsAuth for WebSockets, etc.).
//!
//! Templates:
//!   ValidateKey — constant-time API key check; Err(String) on mismatch.
//!                 B'-mode with a `where TArgs has { apiKey: String }` row
//!                 constraint (docs/56 / D115): dedups to one specialised
//!                 function per matched-function shape across every
//!                 consumer, instead of C-mode's per-use-site recompile.
//!
//! See docs/26-aspects.md, docs/27-aspect-libraries.md, and docs/56.
@runtime_checked
package Auth.Aspects

import Std.Core
import Auth

// ─── ValidateKey ─────────────────────────────────────────────────────────────
/// Validate a static API key on every matched handler call.
///
/// The handler must declare a parameter named `apiKey: String` — the value
/// extracted from a header, query parameter, or message attribute by the
/// framework dispatcher.
///
/// Uses constant-time comparison (Auth.verifyApiKey) to prevent timing
/// attacks on the credential comparison path (RFC 7235).
///
/// This is a B'-mode template gated by a `where TArgs has { apiKey: String }`
/// row constraint (docs/56 / D115): the matched handler's `apiKey` parameter
/// is threaded into the shared specialised function as a typed field read,
/// so every consumer of a given handler shape shares one compiled copy
/// instead of C-mode's per-use-site recompile.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled     Bool   — master switch; false passes all calls through (default: true)
///   @sensitive
///   expectedKey String — REQUIRED: the expected API key value
///
/// Return type: the matched handler must return Result[T, String].
/// Short-circuits with Err("API key is invalid") on mismatch, or
/// Err("API key is missing") when the key argument is empty.
@stable(since = "0.1")
pub aspect ValidateKey {
  config {
    enabled: Bool = true
    @sensitive
    expectedKey: String
  }
  around(call) -> ret where TArgs has { apiKey: String } {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.apiKey == "" {
        ret = Err("API key is missing")
      } else {
        val ok = Auth.verifyApiKey(args.apiKey, expectedKey)
        if ok {
          ret = call.proceed()
        } else {
          ret = Err("API key is invalid")
        }
      }
    }
  }
}
