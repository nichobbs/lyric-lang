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
func findLocalInterface(items: in List[Item], name: in String): Option[InterfaceDecl] {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IInterface(id) -> {
        if id.name == name {
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

// Return `decl` with a verbatim `IMplFunc` copy appended for every `IMFunc`
// default method of `ifaceDecl` that `decl` doesn't already provide.
// Returns `decl` unchanged (same identity semantics) when nothing needed
// inheriting, so callers can skip rebuilding the enclosing item.
func withInheritedDefaults(decl: in ImplDecl, ifaceDecl: in InterfaceDecl): ImplDecl {
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
        if not implProvidesMethod(decl, fn.name) {
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

// Rewrite every `IImpl` item in `items`, inheriting default methods from a
// same-file interface declaration where applicable. Items that are not
// `IImpl`, or whose interface isn't declared in this file (cross-package —
// see the module doc's scope note), pass through unchanged.
func synthesiseItems(items: in List[Item]): List[Item] {
  val result: List[Item] = newList()
  var i = 0
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IImpl(decl) -> {
        match findLocalInterface(items, implIfaceName(decl)) {
          case Some(ifaceDecl) -> {
            val newDecl = withInheritedDefaults(decl, ifaceDecl)
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
pub func inheritDefaultsFile(file: in SourceFile): SourceFile {
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = synthesiseItems(file.items),
    span = file.span
  )
}
