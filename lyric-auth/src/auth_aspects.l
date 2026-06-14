//! Auth.Aspects — transport-agnostic authentication aspect templates.
//!
//! Provides reusable template aspects that delegate to lyric-auth verification
//! primitives (Auth.verifyApiKey, Auth.verifyJwt) without coupling to any
//! transport protocol.  Protocol-specific bindings live in the consuming library
//! (Web.Aspects.ApiKey for HTTP, Ws.Aspects.WsAuth for WebSockets, etc.).
//!
//! Templates:
//!   ValidateKey — constant-time API key check; Err(String) on mismatch.
//!                 C-mode (@inline_template): reads args.apiKey.
//!
//! See docs/26-aspects.md and docs/27-aspect-libraries.md.
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
/// This is a C-mode template (@inline_template): the body is re-compiled
/// inside the consumer's package so it can read args.apiKey.
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
@inline_template
pub aspect ValidateKey {
  config {
    enabled: Bool = true
    @sensitive
    expectedKey: String
  }
  requires: args.apiKey != ""
  // required — no default
  // handler must declare an apiKey parameter
  around(call) -> ret {
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
