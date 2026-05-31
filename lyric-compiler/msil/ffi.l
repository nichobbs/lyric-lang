// Msil.Ffi: table-driven @externTarget resolver (no runtime reflection — Lyric-emitted PEs trip Type.GetType); see D-progress-268 for trade-offs.

package Msil.Ffi

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Parser

// ── Resolve hint (#370) ──────────────────────────────────────────────────────

pub union ResolveHint {
  case RHEither       // default: assume static
  case RHStaticOnly   // @externStatic
  case RHInstanceOnly // @externInstance
}

// ── Hint extraction (#370) ───────────────────────────────────────────────────

pub func hintFromAnnotations(anns: in List[Annotation]): ResolveHint {
  var i = 0
  var hasStatic = false
  var hasInstance = false
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 {
      if segs[0] == "externStatic"   { hasStatic   = true }
      if segs[0] == "externInstance" { hasInstance = true }
    }
    i = i + 1
  }
  // Both present → diagnostic concern of the caller; default to
  // static so the program at least builds while the user fixes
  // their annotations.
  if hasStatic and hasInstance { return RHStaticOnly }
  if hasStatic   { return RHStaticOnly }
  if hasInstance { return RHInstanceOnly }
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
      if segs[0] == "externStatic"   { hasStatic   = true }
      if segs[0] == "externInstance" { hasInstance = true }
    }
    i = i + 1
  }
  hasStatic and hasInstance
}

// ── Target-string parsing ────────────────────────────────────────────────────

pub record TargetSplit {
  typeName:   String   // fully-qualified CLR type name
  memberName: String   // method/field name (or ".ctor")
  isCtor:     Bool     // true when target ended in "..ctor"
}

pub func splitTarget(target: in String): Option[TargetSplit] {
  if Str.endsWith(target, "..ctor") {
    val ty = Str.substring(target, 0, target.length - 6)
    return Some(value = TargetSplit(typeName = ty, memberName = ".ctor", isCtor = true))
  }
  match Str.lastIndexOf(target, ".") {
    case None -> None
    case Some(dotIdx) -> {
      val ty   = Str.substring(target, 0, dotIdx)
      val name = Str.substring(target, dotIdx + 1, target.length - dotIdx - 1)
      Some(value = TargetSplit(typeName = ty, memberName = name, isCtor = false))
    }
  }
}

// Holder for splitTypeFqn's result — a bare `(ns, name)` tuple
// confuses the parser as a call expression in trailing position.
pub record TypeFqnSplit {
  ns:   String
  name: String
}

// Split "System.Net.Http.HttpClient" into ("System.Net.Http",
// "HttpClient").  Types with no namespace return ("", typeFqn).
pub func splitTypeFqn(typeFqn: in String): TypeFqnSplit {
  match Str.lastIndexOf(typeFqn, ".") {
    case None -> TypeFqnSplit(ns = "", name = typeFqn)
    case Some(dotIdx) -> {
      val ns   = Str.substring(typeFqn, 0, dotIdx)
      val name = Str.substring(typeFqn, dotIdx + 1, typeFqn.length - dotIdx - 1)
      TypeFqnSplit(ns = ns, name = name)
    }
  }
}

// ── Resolved-target shape ────────────────────────────────────────────────────

pub record FfiResolved {
  assemblyName: String
  namespaceStr: String
  typeName:     String
  memberName:   String
  isStatic:     Bool
  isCtor:       Bool
}

// ── Type → assembly table ────────────────────────────────────────────────────

// Look up the simple assembly name hosting a given CLR type.  Prefix
// matches are checked longest-first so `System.Console` wins over
// `System` (which falls back to System.Runtime).
//
// The table covers every BCL surface the stdlib actually externs into
// today.  Anything not matched defaults to `System.Runtime`, which is
// the .NET facade that type-forwards into System.Private.CoreLib —
// safe for `System.*` core types like Math, String, Int32, etc.
pub func clrAssemblyForType(typeFqn: in String): String {
  // System.Console (System.Console.dll)
  if Str.startsWith(typeFqn, "System.Console") { return "System.Console" }
  // I/O surfaces (System.IO.FileSystem.dll)
  if Str.startsWith(typeFqn, "System.IO.File")
      or Str.startsWith(typeFqn, "System.IO.Directory")
      or Str.startsWith(typeFqn, "System.IO.Path") { return "System.IO.FileSystem" }
  // Streams (System.IO is in System.Runtime; the specific Streams
  // helpers live in System.Runtime.Extensions on .NET 6+ but the
  // forwarder makes them resolvable via System.Runtime).
  // Net (System.Net.Primitives / System.Net.Http)
  if Str.startsWith(typeFqn, "System.Net.Http") { return "System.Net.Http" }
  if Str.startsWith(typeFqn, "System.Net") { return "System.Net.Primitives" }
  // Regex (System.Text.RegularExpressions.dll)
  if Str.startsWith(typeFqn, "System.Text.RegularExpressions") {
    return "System.Text.RegularExpressions"
  }
  // JSON (System.Text.Json.dll)
  if Str.startsWith(typeFqn, "System.Text.Json") { return "System.Text.Json" }
  // Encoding (System.Runtime.Extensions / System.Runtime)
  // Linq (System.Linq.dll)
  if Str.startsWith(typeFqn, "System.Linq") { return "System.Linq" }
  // Collections — generic types are in System.Collections, concurrent
  // in System.Collections.Concurrent.
  if Str.startsWith(typeFqn, "System.Collections.Concurrent") {
    return "System.Collections.Concurrent"
  }
  if Str.startsWith(typeFqn, "System.Collections.Generic") {
    return "System.Collections"
  }
  if Str.startsWith(typeFqn, "System.Collections") {
    return "System.Collections.NonGeneric"
  }
  // Threading / tasks
  if Str.startsWith(typeFqn, "System.Threading.Tasks") {
    return "System.Threading.Tasks"
  }
  if Str.startsWith(typeFqn, "System.Threading") {
    return "System.Threading"
  }
  // Process / diagnostics
  if Str.startsWith(typeFqn, "System.Diagnostics.Process") {
    return "System.Diagnostics.Process"
  }
  if Str.startsWith(typeFqn, "System.Diagnostics") {
    return "System.Runtime.Extensions"
  }
  // Security cryptography
  if Str.startsWith(typeFqn, "System.Security.Cryptography") {
    return "System.Security.Cryptography"
  }
  // Globalization (in System.Runtime)
  // Reflection (System.Reflection / Runtime.Loader for some)
  if Str.startsWith(typeFqn, "System.Reflection") {
    return "System.Runtime"
  }
  // Lyric host helpers — same DLL as the emitter.
  if Str.startsWith(typeFqn, "Lyric.Emitter")
      or Str.startsWith(typeFqn, "Lyric.Stdlib") { return "Lyric.Emitter" }
  // Default: System.Runtime is the .NET facade that type-forwards
  // most System.* types (String, Int32, Math, Object, Type, Exception,
  // DateTime, TimeSpan, Guid, Uri, etc.).  This covers the long tail.
  "System.Runtime"
}

// True when `clrAssemblyForType` can resolve `typeFqn` to a real reference
// assembly rather than guessing the `System.Runtime` default (#1504 H8).
// Resolvable = a `System.*` BCL type (forwarded by / mapped to a concrete
// facade) or a `Lyric.*` internal host (`Lyric.Emitter`, `Lyric.Stdlib`,
// `Lyric.Jvm.Hosts`).  Anything else — a typo (`Sytem.Console`) or an
// unsupported third-party type — would silently mis-bind to `System.Runtime`
// and fail at runtime with an opaque `TypeLoadException`; callers use this to
// emit a clear diagnostic instead.
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
// signature mismatch (caught by the cross-package round-trip self-test).
pub func clrIsValueType(typeFqn: in String): Bool {
  typeFqn == "System.Guid"
    or typeFqn == "System.DateTime"
    or typeFqn == "System.TimeSpan"
    or typeFqn == "System.DateTimeOffset"
    or typeFqn == "System.Threading.CancellationToken"
    or typeFqn == "System.Globalization.NumberStyles"
    or typeFqn == "System.Text.RegularExpressions.RegexOptions"
}

// ── Resolver ─────────────────────────────────────────────────────────────────

// `paramArity` was carried over from the earlier reflection-based
// cascade (`MethodInfo.GetParameters().Length`) that the resolver no
// longer uses — the table-driven resolver derives everything from
// the target string + the Lyric param/return types.  Leaving the
// parameter in place would be unused noise (#792), so it is gone;
// callers no longer pass it.
pub func resolveExternTarget(
  target: in String,
  hint:   in ResolveHint
): Option[FfiResolved] {
  match splitTarget(target) {
    case None -> None
    case Some(ts) -> {
      val sp = splitTypeFqn(ts.typeName)
      val ns = sp.ns
      val tyName = sp.name
      val asmName = clrAssemblyForType(ts.typeName)
      val isStatic = match hint {
        case RHStaticOnly   -> true
        case RHInstanceOnly -> false
        // No hint → assume static.  Callers must annotate instance
        // externs with @externInstance explicitly; the cascade can't
        // disambiguate without reflection and the default is the
        // safer choice (most BCL externs in the stdlib are static).
        case RHEither       -> true
      }
      // Constructors always emit `newobj` (treated as static in
      // FfiResolved — the codegen branches on `isCtor`).
      val isStaticFinal = if ts.isCtor { true } else { isStatic }
      Some(value = FfiResolved(
        assemblyName = asmName,
        namespaceStr = ns,
        typeName     = tyName,
        memberName   = ts.memberName,
        isStatic     = isStaticFinal,
        isCtor       = ts.isCtor))
    }
  }
}
