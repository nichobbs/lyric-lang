//! Msil.Ffi: table-driven @externTarget resolver (no runtime reflection — Lyric-emitted PEs trip Type.GetType); see D-progress-268 for trade-offs.
package Msil.Ffi

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Parser

// ── Resolve hint (#370) ──────────────────────────────────────────────────────
pub union ResolveHint {
  case RHEither
  // default: assume static
  case RHStaticOnly
  // @externStatic
  case RHInstanceOnly
  // @externInstance
  // ── Hint extraction (#370) ───────────────────────────────────────────────────
}

pub func hintFromAnnotations(anns: in List[Annotation]): ResolveHint {
  var i = 0
  var hasStatic = false
  var hasInstance = false
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 {
      if segs[0] == "externStatic" {
        hasStatic = true
      }
      if segs[0] == "externInstance" {
        hasInstance = true
      }
    }
    i = i + 1
  }
  // Both present → diagnostic concern of the caller; default to
  // static so the program at least builds while the user fixes
  // their annotations.
  if hasStatic and hasInstance {
    return RHStaticOnly
  }
  if hasStatic {
    return RHStaticOnly
  }
  if hasInstance {
    return RHInstanceOnly
  }
  RHEither
}

// Keep in sync with `lyric/type_checker/typechecker_stmts.l`
// `hasConflictingExternHints` (#803).  Both functions look for the
// same annotation pair; extracting shared annotation-name constants
// is a follow-up tracked in the `Lyric.Annotations` rollup.
pub func hasConflictingHints(anns: in List[Annotation]): Bool {
  var i = 0
  var hasStatic = false
  var hasInstance = false
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 {
      if segs[0] == "externStatic" {
        hasStatic = true
      }
      if segs[0] == "externInstance" {
        hasInstance = true
      }
    }
    i = i + 1
  }
  hasStatic and hasInstance
}

// ── Target-string parsing ────────────────────────────────────────────────────
pub record TargetSplit {
  typeName: String
  // fully-qualified CLR type name
  memberName: String
  // method/field name (or ".ctor")
  isCtor: Bool
  // true when target ended in "..ctor"
}

pub func splitTarget(target: in String): Option[TargetSplit] {
  if Str.endsWith(target, "..ctor") {
    val ty = Str.substring(target, 0, target.length - 6)
    return Some(value = TargetSplit(typeName = ty, memberName = ".ctor", isCtor = true))
  }
  match Str.lastIndexOf(target, ".") {
    case None -> None
    case Some(dotIdx) -> {
      val ty = Str.substring(target, 0, dotIdx)
      val name = Str.substring(target, dotIdx + 1, target.length - dotIdx - 1)
      Some(value = TargetSplit(typeName = ty, memberName = name, isCtor = false))
    }
  }
}

// Holder for splitTypeFqn's result — a bare `(ns, name)` tuple
// confuses the parser as a call expression in trailing position.
pub record TypeFqnSplit {
  ns: String
  name: String
  // Split "System.Net.Http.HttpClient" into ("System.Net.Http",
  // "HttpClient").  Types with no namespace return ("", typeFqn).
}

pub func splitTypeFqn(typeFqn: in String): TypeFqnSplit {
  match Str.lastIndexOf(typeFqn, ".") {
    case None -> TypeFqnSplit(ns = "", name = typeFqn)
    case Some(dotIdx) -> {
      val ns = Str.substring(typeFqn, 0, dotIdx)
      val name = Str.substring(typeFqn, dotIdx + 1, typeFqn.length - dotIdx - 1)
      TypeFqnSplit(ns = ns, name = name)
    }
  }
}

// ── Resolved-target shape ────────────────────────────────────────────────────
pub record FfiResolved {
  namespaceStr: String
  typeName: String
  memberName: String
  isStatic: Bool
  isCtor: Bool
  // True when the assembly for `typeFqn` can be resolved — either from the
  // metadata type-index (the authoritative source) or from the Lyric-host
  // fallback (Lyric.Emitter / Lyric.Stdlib).  Anything else — a typo
  // (`Sytem.Console`) or an unsupported third-party type — would silently
  // mis-bind and fail at runtime; callers use this to emit a clear diagnostic.
  // `Lyric.Jvm.Hosts` is covered by the Lyric.* prefix check.
}

pub func clrAssemblyResolvable(typeFqn: in String): Bool {
  Str.startsWith(typeFqn, "System.") or Str.startsWith(typeFqn, "Lyric.")
}

// True when `typeFqn` is a known BCL *value type* (struct or enum).  Extern
// types that map to one of these (`extern type Uuid = "System.Guid"`, etc.)
// must encode as ELEMENT_TYPE_VALUETYPE (0x11) + TypeRef in cross-package
// MemberRef signatures so the consumer's reference matches the producer DLL's
// `valuetype System.X` MethodDef signature — a CLASS / OBJECT encoding mismatch
// faults at run time with `Method not found` (#1602).
//
// The list is the closed set of value-typed externs the stdlib `_kernel/`
// boundary declares today (see `lyric-stdlib/std/_kernel/*.l`).  Reference-type
// externs (HttpClient, Regex, Stream, …) are deliberately absent — they keep
// the existing CLASS / OBJECT encoding.  When a new value-typed extern is
// added to the kernel, it must be added here too; an omission re-introduces the
// signature mismatch.  A CI-time cross-check against the `_kernel/` externs is
// tracked in #1802 (today there is no automated guard).
pub func clrIsValueType(typeFqn: in String): Bool {
  typeFqn == "System.Guid" or typeFqn == "System.DateTime" or typeFqn == "System.TimeSpan" or
    typeFqn == "System.DateTimeOffset" or
    typeFqn == "System.Threading.CancellationToken" or
    typeFqn == "System.Globalization.NumberStyles" or
    typeFqn == "System.Text.RegularExpressions.RegexOptions"
}

// ── Resolver ─────────────────────────────────────────────────────────────────
// `paramArity` was carried over from the earlier reflection-based
// cascade (`MethodInfo.GetParameters().Length`) that the resolver no
// longer uses — the table-driven resolver derives everything from
// the target string + the Lyric param/return types.  Leaving the
// parameter in place would be unused noise (#792), so it is gone;
// callers no longer pass it.
pub func resolveExternTarget(target: in String, hint: in ResolveHint): Option[FfiResolved] {
  match splitTarget(target) {
    case None -> None
    case Some(ts) -> {
      val sp = splitTypeFqn(ts.typeName)
      val ns = sp.ns
      val tyName = sp.name
      val isStatic = match hint {
        case RHStaticOnly -> true
        case RHInstanceOnly -> false
        // No hint → assume static.  Callers must annotate instance
        // externs with @externInstance explicitly; the cascade can't
        // disambiguate without reflection and the default is the
        // safer choice (most BCL externs in the stdlib are static).
        case RHEither -> true
      }
      // Constructors always emit `newobj` (treated as static in
      // FfiResolved — the codegen branches on `isCtor`).
      val isStaticFinal = if ts.isCtor { true } else { isStatic }
      Some(
        value = FfiResolved(
          namespaceStr = ns,
          typeName = tyName,
          memberName = ts.memberName,
          isStatic = isStaticFinal,
          isCtor = ts.isCtor
        )
      )
    }
  }
}
