// msil/ffi.l — Msil.Ffi
//
// FFI resolver for the self-hosted MSIL emitter (#370 + Phase R6).
// Resolves `@externTarget("Type.Member")` declarations against the BCL
// types loaded into the compiler's own AppDomain, then emits the
// AssemblyRef / TypeRef / MemberRef plumbing the codegen needs to emit
// a direct `call` / `callvirt` / `newobj` to the BCL target.
//
// Cascade order (mirrors the F# bootstrap `resolveExternTarget`):
//   constructor (..ctor)  -> handled separately, before the cascade.
//   static-typed          -> static method whose params exactly match.
//   instance-typed        -> instance method (receiver = first Lyric param).
//   static-arity          -> static method matching arity only.
//   instance-arity        -> instance method matching arity only.
//   property-getter       -> static property accessor (e.g. Encoding.UTF8).
//   static-field          -> static field read (e.g. TimeSpan.Zero).
//
// #370 resolve hint: `@externStatic` skips the instance branches;
// `@externInstance` skips the static branches.
//
// Coverage today (MVP):
//   * Static method on a non-generic BCL type with primitive / String
//     parameter and return types.
//   * Constructor on a non-generic BCL type with primitive parameters.
//   * Instance method (receiver-typed by Lyric param).
//   * Property getter and static field reads.
//
// Deferred: generic type instantiations (List[T].Add), ref/out
// parameters, with-defaults trailing arguments.

package Msil.Ffi

import Std.Core
import Std.Collections
import Std.String as Str
import Std.ReflectionHost
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
    // The caller (codegen) emits the diagnostic; resolver falls back
    // to the static-only behaviour so the program at least builds.
    return RHStaticOnly
  }
  if hasStatic   { return RHStaticOnly }
  if hasInstance { return RHInstanceOnly }
  RHEither
}

// True when both @externStatic and @externInstance are present.
// Caller emits the diagnostic; this is purely a predicate.
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

// Split "System.Net.Http.HttpClient.SendAsync" into ("System.Net.Http.HttpClient",
// "SendAsync") at the LAST dot.  The two-dot `..ctor` suffix marks a
// constructor.
pub record TargetSplit {
  typeName:   String   // fully-qualified CLR type name
  memberName: String   // method/field/property name (or ".ctor")
  isCtor:     Bool     // true when the target ended in "..ctor"
}

pub func splitTarget(target: in String): Option[TargetSplit] {
  // Handle "..ctor" suffix explicitly.
  if Str.endsWith(target, "..ctor") {
    val ty = Str.substring(target, 0, target.length - 6)
    return Some(value = TargetSplit(typeName = ty, memberName = ".ctor", isCtor = true))
  }
  match Str.lastIndexOf(target, ".") {
    case None -> None
    case Some(dotIdx) -> {
      val ty   = Str.substring(target, 0, dotIdx)
      val name = Str.substring(target, dotIdx + 1)
      Some(value = TargetSplit(typeName = ty, memberName = name, isCtor = false))
    }
  }
}

// ── CLR type lookup ──────────────────────────────────────────────────────────

// Try System.Type.GetType first; fall back to walking the loaded
// assemblies in the compiler's own AppDomain when GetType returns null
// (the BCL doesn't probe non-mscorlib assemblies by default).
pub func findClrType(qualifiedName: in String): Option[ClrType] {
  match typeGetType(qualifiedName) {
    case Some(t) -> return Some(value = t)
    case None    -> ()
  }
  val domain = currentDomain()
  val asms   = domainAssemblies(domain)
  var i = 0
  while i < asms.length {
    match assemblyGetType(asms[i], qualifiedName) {
      case Some(t) -> return Some(value = t)
      case None    -> ()
    }
    i = i + 1
  }
  None
}

// Return the simple name of the assembly hosting `t`
// (e.g. "System.Console" for System.Console).
pub func clrTypeAssemblyName(t: in ClrType): String {
  assemblyNameName(assemblyGetName(typeAssembly(t)))
}

// Return the namespace of a CLR type (empty for global namespace).
pub func clrTypeNamespace(t: in ClrType): String {
  typeNamespace(t)
}

// Return the simple name of a CLR type (without namespace).
pub func clrTypeSimpleName(t: in ClrType): String {
  typeName(t)
}

// ── Method cascade ───────────────────────────────────────────────────────────

// Resolved FFI target: everything the codegen needs to register the
// AssemblyRef / TypeRef / MemberRef row and emit the right call.
pub record FfiResolved {
  assemblyName: String   // simple assembly name (e.g. "System.Runtime")
  namespaceStr: String   // type namespace (e.g. "System")
  typeName:     String   // type simple name (e.g. "Math")
  memberName:   String   // method/field name (or ".ctor")
  isStatic:     Bool     // true for static methods and ctors
  isCtor:       Bool     // true for ctor specifically
  isField:      Bool     // true for static field reads
}

// Resolve a `@externTarget("Type.Member")` declaration to the bits the
// codegen needs.  Returns None when the target can't be located in
// loaded BCL assemblies; the caller is responsible for emitting the
// diagnostic.
//
// `paramArity` is the number of Lyric parameters declared on the
// extern; the cascade uses arity to disambiguate overloads (the F#
// resolver does the same — see Emitter.fs:resolveExternTarget).
// `hint` lets `@externStatic` / `@externInstance` short-circuit the
// cascade (#370).
pub func resolveExternTarget(
  target:     in String,
  paramArity: in Int,
  hint:       in ResolveHint
): Option[FfiResolved] {
  match splitTarget(target) {
    case None -> None
    case Some(ts) -> {
      match findClrType(ts.typeName) {
        case None -> None
        case Some(t) -> {
          val asmName = clrTypeAssemblyName(t)
          val ns      = clrTypeNamespace(t)
          val tyName  = clrTypeSimpleName(t)

          if ts.isCtor {
            return Some(value = FfiResolved(
              assemblyName = asmName,
              namespaceStr = ns,
              typeName     = tyName,
              memberName   = ".ctor",
              isStatic     = true,   // ctors emit `newobj`, no receiver
              isCtor       = true,
              isField      = false))
          }

          val allowStatic   = match hint {
            case RHEither       -> true
            case RHStaticOnly   -> true
            case RHInstanceOnly -> false
          }
          val allowInstance = match hint {
            case RHEither       -> true
            case RHStaticOnly   -> false
            case RHInstanceOnly -> true
          }

          // Walk methods.  Static-first cascade with arity match.
          val methods = typeGetMethods(t)
          if allowStatic {
            var i = 0
            while i < methods.length {
              val m = methods[i]
              if methodIsStatic(m) and methodName(m) == ts.memberName
                  and methodGetParameters(m).length == paramArity {
                return Some(value = FfiResolved(
                  assemblyName = asmName,
                  namespaceStr = ns,
                  typeName     = tyName,
                  memberName   = ts.memberName,
                  isStatic     = true,
                  isCtor       = false,
                  isField      = false))
              }
              i = i + 1
            }
          }
          if allowInstance and paramArity >= 1 {
            var i = 0
            while i < methods.length {
              val m = methods[i]
              if not methodIsStatic(m) and methodName(m) == ts.memberName
                  and methodGetParameters(m).length == paramArity - 1 {
                return Some(value = FfiResolved(
                  assemblyName = asmName,
                  namespaceStr = ns,
                  typeName     = tyName,
                  memberName   = ts.memberName,
                  isStatic     = false,
                  isCtor       = false,
                  isField      = false))
              }
              i = i + 1
            }
          }
          // Property getter fallback (static only — `get_Foo`).
          if allowStatic {
            match typeGetProperty(t, ts.memberName) {
              case Some(p) ->
                if propertyCanRead(p) {
                  match propertyGetGetMethod(p) {
                    case Some(g) ->
                      if methodIsStatic(g) {
                        return Some(value = FfiResolved(
                          assemblyName = asmName,
                          namespaceStr = ns,
                          typeName     = tyName,
                          memberName   = "get_" + ts.memberName,
                          isStatic     = true,
                          isCtor       = false,
                          isField      = false))
                      } else { () }
                    case None -> ()
                  }
                } else { () }
              case None -> ()
            }
          }
          // Static field fallback.
          if allowStatic {
            match typeGetField(t, ts.memberName) {
              case Some(f) ->
                if fieldIsStatic(f) {
                  return Some(value = FfiResolved(
                    assemblyName = asmName,
                    namespaceStr = ns,
                    typeName     = tyName,
                    memberName   = ts.memberName,
                    isStatic     = true,
                    isCtor       = false,
                    isField      = true))
                } else { () }
              case None -> ()
            }
          }
          None
        }
      }
    }
  }
}
