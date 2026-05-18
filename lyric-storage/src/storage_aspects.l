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
import Std.String as Str
import Storage
import Storage.Kernel.Net
import Storage.Kernel.Jvm

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
      storageKernelAuditLog(call.qualifiedName, logLevel, "")
      ret = call.proceed()
      match ret {
        case Ok(_)  -> storageKernelAuditLog(call.qualifiedName + ":ok",  logLevel, "")
        case Err(e) -> storageKernelAuditLog(call.qualifiedName + ":err", "warn",   e.message)
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

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val norm   = normalisedKey(args.key)
      val reason = traversalReason(args.key, norm)
      if reason != "" {
        ret = Err(StorageError(
          message = "storage key rejected: " + reason,
          code    = "INVALID_KEY"))
      } else if not allowDots and containsDotDot(norm) {
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

// Normalise a key for traversal-detection: URL-decode the path-relevant
// percent-encodings (only `.`, `/`, `\`), fold backslashes to forward
// slashes, and repeat until the output stabilises.  The iterative approach
// handles double-encoded sequences (e.g. `%252e%252e` → `%2e%2e` → `..`).
// The returned string is *only* for inspection by `containsDotDot` /
// `traversalReason`; it is never passed downstream to the storage backend.
func normalisedKey(s: in String): String {
  // Cap iterations to bound worst-case cost on adversarial keys.
  // Each iteration strictly reduces the length of any percent-encoded prefix
  // (e.g. %25 → %, %252e → %2e → .) so the loop converges; the cap is a
  // defence-in-depth guard, not a correctness measure.
  val maxIter = 20
  var cur  = s
  var prev = ""
  var iter = 0
  while cur != prev and iter < maxIter {
    prev    = cur
    val a   = Str.replace(cur,  "%25", "%")
    val b   = Str.replace(a,    "%2e", ".")
    val c   = Str.replace(b,    "%2E", ".")
    val d   = Str.replace(c,    "%2f", "/")
    val e   = Str.replace(d,    "%2F", "/")
    val f   = Str.replace(e,    "%5c", "\\")
    val g   = Str.replace(f,    "%5C", "\\")
    cur     = Str.replace(g,    "\\",  "/")
    iter    = iter + 1
  }
  cur
}

// Reject empty, leading-slash, null-byte, and clearly-bogus keys with
// a structured reason.  Returns "" when the key clears the cheap
// rejections.  Accepts a pre-computed normalised key (`norm`) to avoid
// calling normalisedKey twice.
func traversalReason(s: in String, norm: in String): String {
  if s == "" {
    return "key must not be empty"
  }
  if Str.contains(s, "\u{0000}") {
    return "key must not contain null bytes"
  }
  if norm.length > 0 and norm.charAt(0).toString() == "/" {
    return "key must not be absolute or start with '/'"
  }
  return ""
}

// Checks for path-traversal via `..` segments.  The caller is expected
// to pass a normalised key (percent-encodings expanded, backslashes
// folded to forward slashes) so this check catches `%2e%2e`, `..%2f`,
// `..\foo`, and `../foo` uniformly.
func containsDotDot(s: in String): Bool {
  val limit = s.length - 1
  var i     = 0
  while i < limit {
    if s.charAt(i).toString() == "." and s.charAt(i + 1).toString() == "." {
      return true
    }
    i = i + 1
  }
  return false
}

// ─── Kernel dispatchers (target-gated) ────────────────────────────────────────

@cfg(feature = "dotnet")
func storageKernelAuditLog(operation: in String, level: in String, detail: in String): Unit {
  Storage.Kernel.Net.auditLog(operation, level, detail)
}
@cfg(feature = "jvm")
func storageKernelAuditLog(operation: in String, level: in String, detail: in String): Unit {
  Storage.Kernel.Jvm.auditLog(operation, level, detail)
}
