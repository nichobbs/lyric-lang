/// Storage.Aspects — pub aspect templates for storage cross-cutting concerns.
///
/// Two templates:
///
///   AuditAccess  — B-mode: logs every matched handler call (put, get, delete)
///                  to a structured audit log before proceeding.  Uses
///                  `call.qualifiedName` as the operation identifier.
///
///   ValidateKey  — C-mode (@inline_template): rejects empty or path-traversal
///                  storage keys before the call reaches the handler.  Reads
///                  `args.key` from the concrete handler parameter list.
///
/// Typical consumer usage:
///
///   import Storage.Aspects
///
///   aspect AuditStorage from Storage.Aspects.AuditAccess {
///     matches: name in { put, get, delete }
///     config { logLevel: String = "info" }
///   }
///
///   aspect SafeKeys from Storage.Aspects.ValidateKey {
///     matches: name in { put, get, delete }
///     inside:  AuditStorage
///     config { allowDots: Bool = false }
///   }
///
/// See docs/26-aspects.md §18, docs/27-aspect-libraries.md.

@runtime_checked
package Storage.Aspects

import Std.Core
import Storage
import Storage.Kernel.Net as StorageKernel

// ─── AuditAccess ─────────────────────────────────────────────────────────────

/// Log every matched storage handler call for audit and compliance purposes.
///
/// B-mode: uses `call.qualifiedName` as the operation name; does not inspect
/// individual parameters (which may contain sensitive object data).
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled  Bool   — master switch (default: true)
///   logLevel String — log level string passed to the audit sink: info/warn/debug (default: "info")
@stable(since="0.1")
pub aspect AuditAccess {
  config {
    enabled:  Bool   = true
    logLevel: String = "info"
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      StorageKernel.auditLog(call.qualifiedName, logLevel, "")
      ret = call.proceed()
      match ret {
        case Ok(_)  -> StorageKernel.auditLog(call.qualifiedName + ":ok",  logLevel, "")
        case Err(e) -> StorageKernel.auditLog(call.qualifiedName + ":err", "warn",   e.message)
      }
    }
  }
}

// ─── ValidateKey ─────────────────────────────────────────────────────────────

/// Reject empty or path-traversal storage keys before the handler runs.
///
/// C-mode (@inline_template): body reads `args.key` from the concrete handler.
/// Apply only to handlers that declare a `key: String` parameter; the compiler
/// reports shape error A0042 otherwise.
///
/// The aspect checks:
///   1. The key must not be empty.
///   2. When `allowDots` is false (the default), the key must not contain a
///      ".." path segment (i.e. the substring "..").
///
/// The handler's return type must be `Result[T, StorageError]` for this aspect
/// to compose correctly — the short-circuit path returns `Err(StorageError)`.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled:   Bool — master switch (default: true)
///   allowDots: Bool — when false, keys containing ".." are rejected (default: false)
@stable(since="0.1")
@inline_template
pub aspect ValidateKey {
  config {
    enabled:   Bool = true
    allowDots: Bool = false
  }

  requires:
    args.key != ""    // handler must declare a key: String parameter

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.key == "" {
        ret = Err(StorageError(
          message = "storage key must not be empty",
          code    = "INVALID_KEY"))
      } else if not allowDots and containsDotDot(args.key) {
        ret = Err(StorageError(
          message = "storage key must not contain path traversal segments (\"..\")",
          code    = "INVALID_KEY"))
      } else {
        ret = call.proceed()
      }
    }
  }
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Return true if `s` contains the substring "..".
func containsDotDot(s: in String): Bool {
  val limit = s.length - 1
  var i     = 0
  while i < limit {
    if s.charAt(i) == "." and s.charAt(i + 1) == "." {
      return true
    }
    i = i + 1
  }
  return false
}
