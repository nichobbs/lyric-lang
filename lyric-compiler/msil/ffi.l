// msil/ffi.l — Msil.Ffi
//
// FFI resolver for the self-hosted MSIL emitter (#370 + Phase R6).
// Resolves `@externTarget("Type.Member")` declarations against the BCL
// types loaded into the compiler's own AppDomain, then hands the
// codegen back the pieces it needs (AssemblyRef name, namespace,
// simple type name, member name, calling convention).
//
// The reflection externs the resolver needs (`System.Type.GetType`,
// `System.Reflection.MethodInfo.IsStatic`, etc.) are declared inline
// here rather than in a stdlib `_kernel/` module: when Msil.Ffi
// imported a kernel module, the bootstrap F# emitter dropped
// Std.Core's union-case context from the consuming compilation and
// `case Some(x) ->` patterns failed codegen with E11.  Declaring the
// externs in this compiler package sidesteps that bug.  The kernel-
// boundary ratchet (D038 Decision F) only scans `lyric-stdlib/std/`
// so these declarations don't count toward the cap.
//
// Cascade order (mirrors the F# bootstrap `resolveExternTarget`):
//   constructor (..ctor)  -> separately, before the cascade.
//   static-arity          -> static method matching name + arity.
//   instance-arity        -> instance method matching name + arity-1
//                            (Lyric arg 0 is the receiver).
//
// #370 resolve hint: `@externStatic` skips the instance branches;
// `@externInstance` skips the static branches.

package Msil.Ffi

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Parser

// ── Extern types ─────────────────────────────────────────────────────────────

extern type ClrType         = "System.Type"
extern type ClrAssembly     = "System.Reflection.Assembly"
extern type ClrMethodInfo   = "System.Reflection.MethodInfo"
extern type ClrAssemblyName = "System.Reflection.AssemblyName"
extern type ClrAppDomain    = "System.AppDomain"

// ── Reflection externs (inline to dodge the kernel-import bug) ───────────────

@externTarget("System.Type.GetType")
pub func reflTypeGetType(qualifiedName: in String): ClrType? = ()

@externTarget("System.AppDomain.CurrentDomain")
pub func reflCurrentDomain(): ClrAppDomain = ()

@externTarget("System.AppDomain.GetAssemblies")
pub func reflDomainAssemblies(domain: in ClrAppDomain): slice[ClrAssembly] = ()

@externTarget("System.Reflection.Assembly.GetType")
pub func reflAssemblyGetType(asm: in ClrAssembly, fullName: in String): ClrType? = ()

@externTarget("System.Type.Assembly")
pub func reflTypeAssembly(t: in ClrType): ClrAssembly = ()

@externTarget("System.Reflection.Assembly.GetName")
pub func reflAssemblyGetName(asm: in ClrAssembly): ClrAssemblyName = ()

@externTarget("System.Reflection.AssemblyName.Name")
pub func reflAssemblyNameName(n: in ClrAssemblyName): String = ()

@externTarget("System.Type.Namespace")
pub func reflTypeNamespace(t: in ClrType): String = ()

@externTarget("System.Type.Name")
pub func reflTypeName(t: in ClrType): String = ()

@externTarget("System.Type.GetMethods")
pub func reflTypeGetMethods(t: in ClrType): slice[ClrMethodInfo] = ()

@externTarget("System.Reflection.MethodInfo.Name")
pub func reflMethodName(m: in ClrMethodInfo): String = ()

@externTarget("System.Reflection.MethodInfo.IsStatic")
pub func reflMethodIsStatic(m: in ClrMethodInfo): Bool = ()

@externTarget("System.Reflection.MethodInfo.GetParameters")
pub func reflMethodGetParameters(m: in ClrMethodInfo): slice[ClrAssemblyName] = ()
//  ↑ The actual return type is ParameterInfo[] but we only need
//    `.length` to count parameters — re-using ClrAssemblyName as the
//    opaque element type avoids one more extern type.  The handle is
//    never inspected.

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
  typeName:   String
  memberName: String
  isCtor:     Bool
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

// ── Resolved-target shape ────────────────────────────────────────────────────

pub record FfiResolved {
  assemblyName: String
  namespaceStr: String
  typeName:     String
  memberName:   String
  isStatic:     Bool
  isCtor:       Bool
}

// ── CLR type lookup ──────────────────────────────────────────────────────────

// Try System.Type.GetType first; fall back to walking the loaded
// assemblies in the compiler's own AppDomain when GetType returns
// null.  The `case null ->` arm is recognised by the bootstrap
// emitter as a null-equality test (codegen.fs handles
// PBinding("null", None) specially against a nullable scrutinee).
pub func findClrType(qualifiedName: in String): Option[ClrType] {
  match reflTypeGetType(qualifiedName) {
    case null -> ()
    case t    -> return Some(value = t)
  }
  val domain = reflCurrentDomain()
  val asms   = reflDomainAssemblies(domain)
  var i = 0
  while i < asms.length {
    match reflAssemblyGetType(asms[i], qualifiedName) {
      case null -> ()
      case t    -> return Some(value = t)
    }
    i = i + 1
  }
  None
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
      match findClrType(ts.typeName) {
        case None -> None
        case Some(t) -> {
          val asmName = reflAssemblyNameName(reflAssemblyGetName(reflTypeAssembly(t)))
          val ns      = reflTypeNamespace(t)
          val tyName  = reflTypeName(t)

          if ts.isCtor {
            return Some(value = FfiResolved(
              assemblyName = asmName,
              namespaceStr = ns,
              typeName     = tyName,
              memberName   = ".ctor",
              isStatic     = true,
              isCtor       = true))
          }

          val allowStatic = match hint {
            case RHEither       -> true
            case RHStaticOnly   -> true
            case RHInstanceOnly -> false
          }
          val allowInstance = match hint {
            case RHEither       -> true
            case RHStaticOnly   -> false
            case RHInstanceOnly -> true
          }

          val methods = reflTypeGetMethods(t)

          if allowStatic {
            var i = 0
            while i < methods.length {
              val m = methods[i]
              if reflMethodIsStatic(m) and reflMethodName(m) == ts.memberName
                  and reflMethodGetParameters(m).length == paramArity {
                return Some(value = FfiResolved(
                  assemblyName = asmName,
                  namespaceStr = ns,
                  typeName     = tyName,
                  memberName   = ts.memberName,
                  isStatic     = true,
                  isCtor       = false))
              }
              i = i + 1
            }
          }
          if allowInstance and paramArity >= 1 {
            var i = 0
            while i < methods.length {
              val m = methods[i]
              if not reflMethodIsStatic(m) and reflMethodName(m) == ts.memberName
                  and reflMethodGetParameters(m).length == paramArity - 1 {
                return Some(value = FfiResolved(
                  assemblyName = asmName,
                  namespaceStr = ns,
                  typeName     = tyName,
                  memberName   = ts.memberName,
                  isStatic     = false,
                  isCtor       = false))
              }
              i = i + 1
            }
          }
          None
        }
      }
    }
  }
}
