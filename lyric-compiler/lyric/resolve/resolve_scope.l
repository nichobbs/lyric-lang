//! resolve_scope.l - a file's import fsc and the §4.3 lookup (docs/70, D313).
//!
//! `buildFileScope` turns one file's imports into a `FileScope`.
//! `resolveBare` and `resolvePath` are the only lookups: both take the fsc,
//! so a declaration the file cannot see cannot be found.  A bare name resolves,
//! in order, to
//!
//!   1. a local, parameter or pattern binding (the caller's walk, which holds
//!      the function's locals, answers this before asking here);
//!   2. a declaration of the file's package, from any of its files;
//!   3. a name the file imports: a name of a package it imports whole, or one
//!      it lists, under its rename if it has one.  A name the file sees
//!      through its own import of the declaring package shadows one it sees
//!      only through the re-export of another package it imports whole;
//!   4. the prelude (`Option`, `Result` and their cases).
//!
//! Two candidates from different packages at the same step are T0123.  A name
//! found nowhere is T0020 (T0010 in type position).
package Lyric.Resolve

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols

func importWord(imp: in ImportDecl): String {
  if imp.isPubUse {
    "pub use "
  } else {
    "import "
  }
}

func importItems(sel: in ImportSelector): List[ImportItem] {
  match sel {
    case ISGroup(group) -> group
    case ISSingle(one) -> {
      val single: List[ImportItem] = newList()
      single.add(one)
      single
    }
  }
}

func lastSegment(path: in ModulePath): String {
  if path.segments.count == 0 {
    ""
  } else {
    path.segments[path.segments.count - 1]
  }
}

func addBinding(fsc: in FileScope, b: in NameBinding): Unit {
  match mapGet(fsc.names, b.local) {
    case Some(bs) -> bs.add(b)
    case None -> {
      val bs: List[NameBinding] = newList()
      bs.add(b)
      fsc.names.add(b.local, bs)
    }
  }
}

/// Build the fsc of one file of package `pkg` from its imports.  Every
/// loaded package must already be registered in `tbl`, so that a listed union
/// brings its cases and a whole import reaches what the package re-exports.
pub func buildFileScope(
  tbl: in DeclTable, pkg: in String, fileId: in Int, path: in String, imports: in List[ImportDecl]
): FileScope {
  val fsc = FileScope(
    pkg = pkg,
    fileId = fileId,
    path = path,
    whole = newMap(),
    names = newMap(),
    selected = newMap(),
    aliases = newMap(),
    directPkgs = newMap()
  )
  for imp in imports {
    if imp.isExtern {
      addExternImport(tbl, fsc, imp)
    } else {
      addLyricImport(tbl, fsc, imp)
    }
  }
  fsc
}

func addExternImport(tbl: in DeclTable, fsc: in FileScope, imp: in ImportDecl): Unit {
  val host = modulePathJoin(imp.path.segments)
  val text = importWord(imp) + "extern " + host
  match imp.selector {
    case Some(sel) -> {
      for item in importItems(sel) {
        val local = match item.asAlias { case Some(a) -> a; case None -> item.name }
        bindExtern(tbl, fsc, local, host + "." + item.name, text)
      }
    }
    case None -> {
      val local = match imp.asAlias { case Some(a) -> a; case None -> lastSegment(imp.path) }
      bindExtern(tbl, fsc, local, host, text)
    }
  }
}

func bindExtern(tbl: in DeclTable, fsc: in FileScope, local: in String, fqn: in String, via: in String): Unit {
  val path = externTypeDefPath(fqn)
  val id = internDefPath(tbl.interner, path)
  val known = match declOfId(tbl, id) { case Some(_) -> true; case None -> false }
  if not known {
    val ix = tbl.decls.count
    tbl.decls.add(
      Decl(
        id = id,
        path = path,
        name = local,
        kind = SKExternType,
        vis = DVPublic,
        pkg = "extern",
        parent = None,
        bare = false,
        span = makeSpan(initialPosition(), initialPosition())
      )
    )
    tbl.byId.add(toString(id.id), ix)
  }
  addBinding(fsc, NameBinding(local = local, pkg = "extern", origName = fqn, via = via, renamed = false))
}

func addLyricImport(tbl: in DeclTable, fsc: in FileScope, imp: in ImportDecl): Unit {
  val target = modulePathJoin(imp.path.segments)
  val text = importWord(imp) + target
  if not fsc.directPkgs.containsKey(target) {
    fsc.directPkgs.add(target, text)
  }
  match imp.selector {
    case Some(sel) -> {
      for item in importItems(sel) {
        addSelected(tbl, fsc, target, item, text)
      }
    }
    case None -> match imp.asAlias {
      case Some(alias) -> {
        if not fsc.aliases.containsKey(alias) {
          fsc.aliases.add(alias, target)
        }
      }
      case None -> addWhole(tbl, fsc, target, text)
    }
  }
}

func addWhole(tbl: in DeclTable, fsc: in FileScope, target: in String, text: in String): Unit {
  if fsc.whole.containsKey(target) {
    match fsc.whole[target] {
      case ReachDirect(_) -> ()
      case ReachReexport(_) -> {
        fsc.whole.remove(target)
        fsc.whole.add(target, ReachDirect(via = text))
      }
    }
  } else {
    fsc.whole.add(target, ReachDirect(via = text))
  }
  for q in reexportClosure(tbl, target) {
    if not fsc.whole.containsKey(q) {
      fsc.whole.add(q, ReachReexport(via = text))
    }
  }
}

// `import P.{X}` lists X from P and from each package P re-exports; a listed
// union or enum brings its cases, unless it is renamed (its cases are then
// reached through the new name).
func addSelected(tbl: in DeclTable, fsc: in FileScope, target: in String, item: in ImportItem, text: in String): Unit {
  val via = text + ".{" + item.name + "}"
  val renamed = match item.asAlias { case Some(_) -> true; case None -> false }
  val local = match item.asAlias { case Some(a) -> a; case None -> item.name }
  val pkgs: List[String] = newList()
  pkgs.add(target)
  for q in reexportClosure(tbl, target) {
    pkgs.add(q)
  }
  for p in pkgs {
    addBinding(fsc, NameBinding(local = local, pkg = p, origName = item.name, via = via, renamed = renamed))
    if not renamed {
      fsc.selected.add(p + "|" + item.name, via)
      for d in declsOfPackageNamed(tbl, p, item.name) {
        if symKindIsType(d.kind) {
          for c in casesOf(tbl, d.id) {
            addBinding(fsc, NameBinding(local = c.name, pkg = p, origName = c.name, via = via, renamed = false))
          }
        }
      }
    }
  }
}
