// msil/ffi.l — Msil.Ffi
//
// FFI resolver for the self-hosted MSIL emitter (#370 + Phase R6).
// Resolves `@externTarget("Type.Member")` declarations to the
// AssemblyRef name + namespace + simple type name + member name that
// the codegen needs to emit a direct `call` / `callvirt` / `newobj`
// to the BCL target.
//
// **No runtime reflection.**  The bootstrap F# emitter writes a PE
// whose calling-assembly metadata trips up `System.Type.GetType` and
// `Assembly.GetType(string)` — both return null even for types that
// are demonstrably loaded.  Rather than rely on a runtime cascade
// that doesn't work, the resolver:
//
//   * Splits the `@externTarget` string at the last dot (or
//     `..ctor` suffix) to recover the CLR type FQN and member name.
//   * Looks up the host assembly in a hardcoded table keyed on the
//     leading namespace prefix.  Every type the stdlib actually
//     externs into is covered; types we haven't taught the table
//     about default to `System.Runtime` (the .NET facade that type-
//     forwards into `System.Private.CoreLib`).
//   * Static-vs-instance is taken from the #370 hint annotations
//     (`@externStatic` / `@externInstance`).  Without a hint the
//     resolver defaults to static — callers MUST annotate instance
//     externs explicitly so this can't silently miscompile.
//
// Trade-off vs reflection:
//   + Works end-to-end today.
//   + No dependency on `Type.GetType` being usable from emitted code.
//   - Requires the type→assembly table to be kept in sync as new
//     BCL surfaces enter the externs.  New types not in the table
//     still emit (defaulted to System.Runtime), which works for
//     types forwarded by that facade.
//
// Future improvement: once the underlying `Type.GetType`-from-Lyric-
// PE issue is fixed, swap this back to a reflection cascade so the
// table can retire.

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

// ── Resolver ─────────────────────────────────────────────────────────────────

pub func resolveExternTarget(
  target:     in String,
  paramArity: in Int,
  hint:       in ResolveHint
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
