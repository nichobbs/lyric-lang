// msil/ffi.l — Msil.Ffi
//
// FFI resolver for the self-hosted MSIL emitter (#370 + Phase R6).
//
// **WIP** — the resolver scaffolding is in place but the codegen
// integration in `Msil.Codegen.lowerFuncMsil` is not yet wired up.
// The F# bootstrap compiler currently miscompiles certain match-on-
// nullable patterns from this file when it is imported transitively,
// so the codegen wiring is deferred until either:
//   * the underlying F# bootstrap bug is fixed (#348 / T6 type-checker
//     work), or
// * the self-hosted MSIL emitter bootstraps the kernel itself.

package Msil.Ffi

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Parser

// ── Resolve hint (#370) ──────────────────────────────────────────────────────

pub union ResolveHint {
  case RHEither       // default cascade
  case RHStaticOnly   // @externStatic — skip the instance cascade
  case RHInstanceOnly // @externInstance — skip the static cascade
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
  if hasStatic and hasInstance {
    return RHStaticOnly
  }
  if hasStatic   { return RHStaticOnly }
  if hasInstance { return RHInstanceOnly }
  RHEither
}

// True when both @externStatic and @externInstance are present.
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
  memberName: String   // method/field/property name (or ".ctor")
  isCtor:     Bool     // true when the target ended in "..ctor"
}

// Split "System.Net.Http.HttpClient.SendAsync" into
// ("System.Net.Http.HttpClient", "SendAsync") at the LAST dot.  The
// two-dot ".ctor" suffix marks a constructor.
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
