//! resolve_shadow.l - a declaration that shadows an import (docs/70 §4.3, D350).
//!
//! §4.3 puts a package's own declarations (step 2) before what a file imports
//! (step 3), so a package-local `func f` hides an imported `f`, and every call
//! of `f` in a file that imports it binds to the local one.  That is the rule,
//! not an error, but it is silent: adding a declaration can rebind calls that
//! were written against the import (#8767).  `shadowedImports` lists each such
//! declaration so the checker can warn once at the declaration.
package Lyric.Resolve

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols

/// A declaration of the package that hides an imported name of the same kind.
pub record ShadowedImport {
  name: String
  /// "function", "type" or "value".
  what: String
  /// Where the package declares it.
  span: Span
  /// The package the shadowed declaration comes from, and the import that
  /// reaches it, as written.
  importedPkg: String
  via: String
}

// Functions, types and module values shadow like with like; a member, a case
// or any other kind is never compared.
func shadowClassOf(k: in SymKind): Int {
  match k {
    case SKFunc -> 1
    case SKVal -> 3
    case SKConst -> 3
    case _ -> if symKindIsType(k) { 2 } else { 0 }
  }
}

func shadowWhat(cls: in Int): String {
  if cls == 1 {
    "function"
  } else if cls == 2 {
    "type"
  } else {
    "value"
  }
}

// The first declaration `fsc` imports directly (not through a re-export, not
// the prelude) under `name` and of class `cls`, with the import that reaches it.
func firstShadowed(tbl: in DeclTable, fsc: in FileScope, name: in String, cls: in Int): Option[ShadowedImport] {
  for d in namedDecls(tbl, name, UseValue) {
    if d.pkg != fsc.pkg and shadowClassOf(d.kind) == cls and declCrossPackageVisible(d) and not inPrelude(tbl, d) {
      match mapGet(fsc.whole, d.pkg) {
        case Some(r) -> match r {
          case ReachDirect(via) -> return Some(
            value = ShadowedImport(name = name, what = shadowWhat(cls), span = d.span, importedPkg = d.pkg, via = via)
          )
          case ReachReexport(_) -> ()
        }
        case None -> ()
      }
    }
  }
  match mapGet(fsc.names, name) {
    case Some(bindings) -> {
      for b in bindings {
        if b.pkg != "extern" {
          for d in namedDecls(tbl, b.origName, UseValue) {
            if d.pkg != fsc.pkg and shadowClassOf(d.kind) == cls and bindingCovers(tbl, b, d) and declCrossPackageVisible(d) {
              return Some(
                value = ShadowedImport(name = name, what = shadowWhat(cls), span = d.span, importedPkg = d.pkg, via = b.via)
              )
            }
          }
        }
      }
    }
    case None -> ()
  }
  None
}

/// Every top-level declaration of the package that hides a name some file of
/// the package imports directly, once per declaration, with the span of the
/// declaration (not of the import).
pub func shadowedImports(ctx: in ResolverContext): List[ShadowedImport] {
  val acc: List[ShadowedImport] = newList()
  val seen: Map[String, Bool] = newMap()
  val tbl = ctx.tbl
  for own in tbl.decls {
    val cls = shadowClassOf(own.kind)
    val topLevel = match own.parent { case Some(_) -> false; case None -> true }
    if own.pkg == ctx.pkg and topLevel and cls > 0 {
      val key = own.name + "|" + toString(cls)
      if not seen.containsKey(key) {
        seen.add(key, true)
        var found = false
        for fsc in ctx.scopes {
          if not found {
            match firstShadowed(tbl, fsc, own.name, cls) {
              case Some(s) -> {
                found = true
                acc.add(
                  ShadowedImport(
                    name = s.name,
                    what = s.what,
                    span = own.span,
                    importedPkg = s.importedPkg,
                    via = s.via
                  )
                )
              }
              case None -> ()
            }
          }
        }
      }
    }
  }
  acc
}
