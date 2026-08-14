//! impl_defaults.l — inherit interface default methods into `impl` blocks
//! that don't override them (#6433).
//!
//! docs/01-language-reference.md §2.12 states plainly "Interfaces support
//! default methods" and that "[m]ultiple inheritance of interfaces is
//! permitted; diamond conflicts are resolved by requiring explicit
//! override" — text that only makes sense if a default method's body is
//! actually inherited by a conforming `impl` that doesn't re-declare it.
//! `docs/grammar.ebnf`'s `InterfaceMember` production tags `FunctionDecl`
//! explicitly as `(* default method *)`.  Before this pass, an `impl` that
//! omitted a bodied interface member (`IMFunc`) TYPE-CHECKED (
//! `checkImplConformance` only requires abstract `IMSig` members) but had
//! no method at all for the omitted name once compiled: calling it through
//! the concrete record crashed at runtime on both targets (JVM
//! `NoSuchMethodError`, MSIL "unsupported method" — #6433's repro).
//!
//! The fix is a pre-typecheck `SourceFile -> SourceFile` AST rewrite,
//! mirroring `Lyric.Stubbable`'s shape: for every `impl Iface for Target`
//! in the file, for every `IMFunc` member of `Iface` (also declared in
//! this file — see the scope note below) that the impl does not already
//! provide, append a verbatim copy of the interface method's
//! `FunctionDecl` as a new `IMplFunc` impl member. No `Self` substitution
//! is needed in the synthesis itself: the copied member becomes a real
//! part of the `impl` block, so the EXISTING per-impl `Self` resolution
//! machinery (`registerParamsMsil`'s `selfTypeName` threading, D-progress-
//! 751/753/755) narrows `Self` to the impl's own target type exactly as it
//! does for a hand-written impl method — zero new backend codegen.  An
//! impl that DOES override a default wins outright (no double-registration,
//! checked by name via `implProvidesMethod`).
//!
//! Scope (matching `Lyric.Stubbable`'s own accepted same-file limitation):
//! this pass only sees interfaces declared IN THE SAME FILE as the `impl`.
//! An `impl` of a default-method-bearing interface imported from another
//! package still relies on that interface's own DIM (interface-typed
//! dispatch) path today; cross-package default-method inheritance into a
//! concrete-type call site is a tracked follow-up, not a regression this
//! pass introduces (the crash for that shape is pre-existing and unchanged).
//!
//! Wired into `Lyric.Pipeline.pipeExpandAndRewrite`, after
//! `Lyric.Stubbable`'s own synthesis (so a `@stubbable` interface's
//! synthesized `<Iface>Stub` impl also inherits any default methods) and
//! before `Lyric.Weaver.injectWeaveImports`.
package Lyric.ImplDefaults

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// Last segment of the impl's interface reference — the bare interface name,
// matching how `checkImplConformance` resolves `ifaceName`.
func implIfaceName(decl: in ImplDecl): String {
  val segs = decl.iface.head.segments
  if segs.count == 0 {
    ""
  } else {
    segs[segs.count - 1]
  }
}

// True if the impl already declares a member named `name` (an override, or
// an implementation of an abstract `IMSig` member sharing the name).
func implProvidesMethod(decl: in ImplDecl, name: in String): Bool {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMplFunc(fn) -> {
        if fn.name == name {
          return true
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

// Find an `IInterface` item declared in `items` whose name matches `name`.
// GENERIC interfaces are skipped (treated as not-found, so the impl passes
// through unchanged) — the same guard `Lyric.Stubbable` applies (#6446
// review): a default body referencing the interface's own type parameter
// would be copied into an impl where that parameter isn't in scope, and in
// the collision case where the impl declares a same-named generic of its
// own, would silently bind the WRONG parameter.  No generic interface with
// a default method exists in the ecosystem today; when the backends learn
// to reify interface generics (D-progress-759's deferred feature) this
// guard is where inheritance support starts.
func findLocalInterface(items: in List[Item], name: in String): Option[InterfaceDecl] {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IInterface(id) -> {
        if id.name == name {
          val isGenericIface = match id.generics { case Some(_) -> true; case None -> false }
          if isGenericIface {
            return None
          }
          return Some(value = id)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
}

// Last segment of the impl's TARGET type reference — the bare target name,
// used to key the target-level method namespace for diamond-conflict
// detection (#6447).  A non-`TRef` target (unusual) yields "" and opts out
// of conflict tracking (nothing is synthesized for it anyway unless its
// interface resolves).
func implTargetName(decl: in ImplDecl): String {
  match decl.target.kind {
    case TRef(path) -> {
      if path.segments.count == 0 {
        ""
      } else {
        path.segments[path.segments.count - 1]
      }
    }
    case _ -> ""
  }
}

// Return `decl` with a verbatim `IMplFunc` copy appended for every `IMFunc`
// default method of `ifaceDecl` that `decl` doesn't already provide AND
// whose name is not blocked by the target-level rules (#6447):
//   * `overridden` — the name is hand-written in SOME impl block for this
//     target (this one or a sibling): the explicit override is the spec's
//     diamond resolution, so no copy is synthesized anywhere for it.
//   * `conflicted` — the name would be synthesized from two or more
//     different interfaces onto this target with no override anywhere:
//     the T0117 diagnostic fires (once, in `inheritDefaultsFile`) and no
//     copy is synthesized, so the backends never see a duplicate member.
// Returns `decl` unchanged (same identity semantics) when nothing needed
// inheriting, so callers can skip rebuilding the enclosing item.
func withInheritedDefaults(
  decl: in ImplDecl,
  ifaceDecl: in InterfaceDecl,
  overridden: in Map[String, Bool],
  conflicted: in Map[String, Bool],
): ImplDecl {
  val targetName = implTargetName(decl)
  var changed = false
  val newMembers: List[ImplMember] = newList()
  var i = 0
  while i < decl.members.count {
    newMembers.add(decl.members[i])
    i = i + 1
  }
  i = 0
  while i < ifaceDecl.members.count {
    match ifaceDecl.members[i] {
      case IMFunc(fn) -> {
        val nsKey = targetName + "/" + fn.name
        val blocked = overridden.containsKey(nsKey) or conflicted.containsKey(nsKey)
        if not implProvidesMethod(decl, fn.name) and not blocked {
          newMembers.add(IMplFunc(fn = fn))
          changed = true
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  if not changed {
    decl
  } else {
    ImplDecl(
      generics = decl.generics,
      iface = decl.iface,
      target = decl.target,
      whereClause = decl.whereClause,
      members = newMembers,
      span = decl.span
    )
  }
}

// Pre-scan every `IImpl` in `items`, building the two target-level maps the
// synthesis consults (#6447), and emitting a `T0117` diagnostic per
// unresolved diamond conflict:
//   * `overridden`:  `<Target>/<name>` for every HAND-WRITTEN impl member
//     across all impl blocks (the spec's "explicit override" resolution —
//     an override in ANY impl of the target claims the name for the whole
//     target method namespace).
//   * `conflicted`:  `<Target>/<name>` where two or more DIFFERENT
//     same-file interfaces would each synthesize a default of that name
//     onto the target with no override anywhere — docs/01 §2.12's diamond
//     case, which "is resolved by requiring explicit override".  Without
//     this check the pass would synthesize two same-named members onto one
//     target and the BACKENDS would crash on the duplicate (#6447 review).
func collectTargetNamespace(
  items: in List[Item],
  overridden: in Map[String, Bool],
  conflicted: in Map[String, Bool],
  diags: in List[Diagnostic],
): Unit {
  // First pass: hand-written members claim their names.
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IImpl(decl) -> {
        val tn = implTargetName(decl)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> {
              val k = tn + "/" + fn.name
              if not overridden.containsKey(k) {
                overridden.add(k, true)
              }
            }
            case _ -> {
            }
          }
          mi = mi + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  // Second pass: count distinct default-supplying interfaces per
  // un-overridden target/name; a second supplier is a diamond conflict.
  val defaultFrom: Map[String, String] = newMap()
  i = 0
  while i < items.count {
    match items[i].kind {
      case IImpl(decl) -> {
        val tn = implTargetName(decl)
        match findLocalInterface(items, implIfaceName(decl)) {
          case Some(ifaceDecl) -> {
            var fi = 0
            while fi < ifaceDecl.members.count {
              match ifaceDecl.members[fi] {
                case IMFunc(fn) -> {
                  val k = tn + "/" + fn.name
                  if not overridden.containsKey(k) {
                    match mapGet(defaultFrom, k) {
                      case Some(firstIface) -> {
                        if firstIface != ifaceDecl.name and not conflicted.containsKey(k) {
                          conflicted.add(k, true)
                          diags.add(
                            errorDiagnostic(
                              "T0117",
                              "diamond conflict: interfaces '" + firstIface + "' and '" + ifaceDecl.name +
                                "' both provide a default method '" +
                                fn.name +
                                "' for '" +
                                tn +
                                "'; resolve by overriding '" +
                                fn.name +
                                "' explicitly in an impl block",
                              items[i].span
                            )
                          )
                        }
                      }
                      case None -> defaultFrom.add(k, ifaceDecl.name)
                    }
                  }
                }
                case _ -> {
                }
              }
              fi = fi + 1
            }
          }
          case None -> {
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Rewrite every `IImpl` item in `items`, inheriting default methods from a
// same-file interface declaration where applicable. Items that are not
// `IImpl`, or whose interface isn't declared in this file (cross-package —
// see the module doc's scope note), pass through unchanged.
func synthesiseItems(
  items: in List[Item],
  overridden: in Map[String, Bool],
  conflicted: in Map[String, Bool],
): List[Item] {
  val result: List[Item] = newList()
  var i = 0
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IImpl(decl) -> {
        match findLocalInterface(items, implIfaceName(decl)) {
          case Some(ifaceDecl) -> {
            val newDecl = withInheritedDefaults(decl, ifaceDecl, overridden, conflicted)
            result.add(
              Item(
                docComments = it.docComments,
                annotations = it.annotations,
                visibility = it.visibility,
                kind = IImpl(decl = newDecl),
                span = it.span
              )
            )
          }
          case None -> result.add(it)
        }
      }
      case _ -> result.add(it)
    }
    i = i + 1
  }
  result
}

// Return `file` with every same-file `impl` block's omitted interface
// default methods inherited as real impl members (#6433).
pub record ImplDefaultsResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

pub func inheritDefaultsFile(file: in SourceFile): ImplDefaultsResult {
  val overridden: Map[String, Bool] = newMap()
  val conflicted: Map[String, Bool] = newMap()
  val diags: List[Diagnostic] = newList()
  collectTargetNamespace(file.items, overridden, conflicted, diags)
  val rewritten = SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = synthesiseItems(file.items, overridden, conflicted),
    span = file.span
  )
  ImplDefaultsResult(file = rewritten, diagnostics = diags)
}
