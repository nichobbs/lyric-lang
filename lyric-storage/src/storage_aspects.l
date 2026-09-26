//! Storage.Aspects — pub aspect templates for storage cross-cutting concerns.
//!
//! Two templates:
//!
//!   AuditAccess  — B-mode: logs every matched handler call (put, get, delete)
//!                  to a structured audit log before proceeding.  Uses
//!                  `call.qualifiedName` as the operation identifier.
//!
//!   ValidateKey  — row-constrained B'-mode (docs/56): rejects any key
//!                  `Storage.isSafeKey` rejects before the call reaches the
//!                  handler.  Reads `args.key` from the concrete handler
//!                  parameter list.
//!
//! Typical consumer usage:
//!
//!   import Storage.Aspects
//!
//!   aspect AuditStorage from Storage.Aspects.AuditAccess {
//!     matches: name in { put, get, delete }
//!     config { logLevel: String = "info" }
//!   }
//!
//!   aspect SafeKeys from Storage.Aspects.ValidateKey {
//!     matches: name in { put, get, delete }
//!     inside:  AuditStorage
//!   }
//!
//! See docs/26-aspects.md §18, docs/27-aspect-libraries.md.
@runtime_checked
package Storage.Aspects

import Std.Core
import Storage

// ─── AuditAccess ─────────────────────────────────────────────────────────────
/// Log every matched storage handler call for audit and compliance purposes.
///
/// B-mode: uses `call.qualifiedName` as the operation name; does not inspect
/// individual parameters (which may contain sensitive object data).
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled  Bool   — master switch (default: true)
///   logLevel String — log level string passed to the audit sink: info/warn/debug (default: "info")
@stable(since = "0.1")
pub aspect AuditAccess {
  config {
    enabled: Bool = true
    logLevel: String = "info"
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      Storage.auditLog(call.qualifiedName, logLevel, "")
      ret = call.proceed()
      match ret {
        case Ok(_) -> Storage.auditLog(call.qualifiedName + ":ok", logLevel, "")
        case Err(e) -> Storage.auditLog(call.qualifiedName + ":err", "warn", e.message)
      }
    }
  }
}

// ─── ValidateKey ─────────────────────────────────────────────────────────────
/// Reject unsafe storage keys before the handler runs, with the same rules
/// every `StorageBucket` implementation applies (`Storage.isSafeKey`):
/// empty keys, control characters, absolute keys, `..`, `.` and empty path
/// segments (including percent-encoded forms), double-encoded `%25`
/// payloads, and `.meta.json` sidecar names.
///
/// Row-constrained B'-mode (docs/56 / D115): body reads `args.key` via a
/// `where TArgs has { key: String }` row clause.  Apply only to handlers
/// that declare a `key: String` parameter; the weaver reports A0047
/// otherwise.
///
/// The handler's return type must be `Result[T, StorageError]` for this aspect
/// to compose correctly — the short-circuit path returns
/// `Err(StorageError(code = "INVALID_KEY"))`.
///
/// There are no configuration fields.  A switch that turns the traversal
/// check off would be settable from the environment
/// (`LYRIC_ASPECT_<INSTANTIATION>_<FIELD>`), so anyone who controls the
/// environment could remove it: first an `allowDots` field (#7242), then the
/// `enabled` master switch (#7326) did exactly that.  To stop checking keys,
/// remove the aspect instantiation from the source.
@stable(since = "0.1")
pub aspect ValidateKey {
  // No `requires: isSafeKey(args.key)`: `key` is client-controlled (e.g. an
  // upload path), so a `requires:` clause (D118 elaborates it into a runtime
  // precondition assert) would panic the whole server on a bad key — a
  // remotely-triggerable DoS.  The `around` body fails closed with a graceful
  // `Err(INVALID_KEY)` instead.
  // handler must declare a key: String parameter
  around(call) -> ret where TArgs has { key: String } {
    if Storage.isSafeKey(args.key) {
      ret = call.proceed()
    } else {
      ret = Err(
        StorageError(
          message = "storage key rejected: empty, absolute, a control character, a '.', '..' or empty path " +
            "segment, a double-encoded '%', or a '.meta.json' name",
          code = "INVALID_KEY"
        )
      )
    }
  }
}
