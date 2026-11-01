//! resolve_driver.l - assembling a resolver context (docs/70 §4.4, D313).
//!
//! The context is what the resolver reads for one package: the declarations of
//! the package and of every dependency it can name, and one import scope per
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
    case None -> match imp.asAlias {
      case Some(_) -> false
      case None -> true
    }
  }
}

/// The packages `imports` re-exports whole (`pub use P`).
pub func reexportsOf(imports: in List[ImportDecl]): List[String] {
  val out: List[String] = newList()
  for imp in imports {
    if imp.isPubUse and not imp.isExtern and isWholeImport(imp) {
      val name = modulePathJoin(imp.path.segments)
      if not out.contains(name) {
        out.add(name)
      }
    }
  }
  out
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
    var i = 0
    while i < file.files.count {
      val h = file.files[i]
      scopes.add(buildFileScope(tbl, pkg, i, h.path, h.imports))
      i = i + 1
    }
  }
  ResolverContext(tbl = tbl, pkg = pkg, scopes = scopes)
}

/// The scope of the file `fileId` of the package; the first file's when the
/// id names none (a synthesised node carries no file).
pub func scopeOfFile(ctx: in ResolverContext, fileId: in Int): FileScope {
  if fileId >= 0 and fileId < ctx.scopes.count {
    ctx.scopes[fileId]
  } else {
    ctx.scopes[0]
  }
}
