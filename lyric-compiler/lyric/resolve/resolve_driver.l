//! resolve_driver.l - assembling a resolver context (docs/70 §4.4, D313).
//!
//! The context is what the resolver reads for one package: the declarations of
//! the package and of every dependency it can name, and one import fsc per
//! file of the package.
package Lyric.Resolve

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols

/// A loaded dependency: its declarations as items (parsed source, or items
/// synthesised from its interface) and the packages it re-exports.
pub record DepPackage {
  name: String
  items: List[Item]
  reexports: List[String]
}

/// Everything the resolver reads for the package `pkg`.
pub record ResolverContext {
  tbl: DeclTable
  pkg: String
  scopes: List[FileScope]
}

func isWholeImport(imp: in ImportDecl): Bool {
  match imp.selector {
    case Some(_) -> false
    case None -> match imp.asAlias { case Some(_) -> false; case None -> true }
  }
}

// An import's identity for comparing two lists of imports: its form and text.
func importKey(imp: in ImportDecl): String {
  var key = modulePathJoin(imp.path.segments)
  if imp.isExtern {
    key = "extern " + key
  }
  if imp.isPubUse {
    key = "pub " + key
  }
  match imp.asAlias {
    case Some(a) -> {
      key = key + " as " + a
    }
    case None -> ()
  }
  match imp.selector {
    case Some(sel) -> {
      val items: List[ImportItem] = match sel {
        case ISGroup(g) -> g
        case ISSingle(one) -> {
          val l: List[ImportItem] = newList()
          l.add(one)
          l
        }
      }
      for it in items {
        key = key + "|" + it.name
        match it.asAlias {
          case Some(a) -> {
            key = key + " as " + a
          }
          case None -> ()
        }
      }
    }
    case None -> ()
  }
  key
}

/// The packages `imports` re-exports whole (`pub use P`).
pub func reexportsOf(imports: in List[ImportDecl]): List[String] {
  val acc: List[String] = newList()
  for imp in imports {
    if imp.isPubUse and not imp.isExtern and isWholeImport(imp) {
      val name = modulePathJoin(imp.path.segments)
      if not acc.contains(name) {
        acc.add(name)
      }
    }
  }
  acc
}

/// Build the context for `file`, a package assembled from its files
/// (docs/70 §4.1), against `deps`.  A dependency with the package's own name
/// is dropped: a package is not its own import (D306).
pub func buildResolverContext(
  deps: in List[DepPackage], file: in SourceFile, interner: in DefPathInterner
): ResolverContext {
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  val tbl = newDeclTable(interner)
  for d in deps {
    if d.name != pkg {
      registerPackage(tbl, d.name, d.reexports)
    }
  }
  registerPackage(tbl, pkg, reexportsOf(file.imports))
  for d in deps {
    if d.name != pkg {
      registerItems(tbl, d.name, d.items)
    }
  }
  registerItems(tbl, pkg, file.items)
  val scopes: List[FileScope] = newList()
  if file.files.count == 0 {
    scopes.add(buildFileScope(tbl, pkg, 0, "", file.imports))
  } else {
    // An import a pass added to the package (the plugin expansion's) is in
    // `file.imports` but in no file's header: it serves the declarations the
    // pass synthesised, so every file's scope carries it, as the checker judges
    // a synthesised item by the union of the files' imports.
    val headerKeys: Map[String, Bool] = newMap()
    for h in file.files {
      for imp in h.imports {
        headerKeys.add(importKey(imp), true)
      }
    }
    val added: List[ImportDecl] = newList()
    for imp in file.imports {
      if not headerKeys.containsKey(importKey(imp)) {
        added.add(imp)
      }
    }
    var i = 0
    while i < file.files.count {
      val h = file.files[i]
      val all: List[ImportDecl] = newList()
      for imp in h.imports {
        all.add(imp)
      }
      for imp in added {
        all.add(imp)
      }
      scopes.add(buildFileScope(tbl, pkg, i, h.path, all))
      i = i + 1
    }
  }
  ResolverContext(tbl = tbl, pkg = pkg, scopes = scopes)
}

/// The fsc of the file `fileId` of the package; the first file's when the
/// id names none (a synthesised node carries no file).
pub func scopeOfFile(ctx: in ResolverContext, fileId: in Int): FileScope {
  if fileId >= 0 and fileId < ctx.scopes.count {
    ctx.scopes[fileId]
  } else {
    ctx.scopes[0]
  }
}
