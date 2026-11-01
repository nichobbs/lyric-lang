//! resolve_model.l - Lyric.Resolve data model (docs/70 §4.3-§4.4, D313).
//!
//! The resolver binds every name occurrence of a package, per file, to a
//! declaration identified by `SymbolId`.  This file holds what it produces
//! and what it reads: the declaration table (every declaration of every loaded
//! package, each with its DefPath), a file's import fsc, and the outcome of
//! one lookup.
package Lyric.Resolve

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols

/// How far a declaration is visible: `pub` and `internal` cross a package
/// boundary, an undecorated one does not.
pub union DeclVis {
  case DVPrivate
  case DVInternal
  case DVPublic
}

/// What a declaration is.  A member of a type (a union or enum case) names its
/// owner in `Decl.parent`.
pub union SymKind {
  case SKFunc
  case SKMethod
  case SKVal
  case SKConst
  case SKRecord
  case SKExposedRecord
  case SKUnion
  case SKEnum
  case SKOpaque
  case SKProtected
  case SKDistinct
  case SKAlias
  case SKInterface
  case SKExternType
  case SKWire
  case SKScopeKind
  case SKConfig
  case SKAspect
  case SKUnionCase
  case SKEnumCase
  case SKTest
}

/// A type declaration (the kinds a type position may name).
pub func symKindIsType(k: in SymKind): Bool {
  match k {
    case SKRecord -> true
    case SKExposedRecord -> true
    case SKUnion -> true
    case SKEnum -> true
    case SKOpaque -> true
    case SKProtected -> true
    case SKDistinct -> true
    case SKAlias -> true
    case SKInterface -> true
    case SKExternType -> true
    case _ -> false
  }
}

pub func symKindIsExternType(k: in SymKind): Bool {
  match k {
    case SKExternType -> true
    case _ -> false
  }
}

pub func symKindIsFunc(k: in SymKind): Bool {
  match k {
    case SKFunc -> true
    case _ -> false
  }
}

pub func symKindIsCase(k: in SymKind): Bool {
  match k {
    case SKUnionCase -> true
    case SKEnumCase -> true
    case _ -> false
  }
}

/// One declaration.  `bare` is true when a bare name can mean it: a top-level
/// declaration or a union/enum case.  A method, whose DefPath nests under its
/// type's, is reached through its receiver and is not indexed by name.
pub record Decl {
  id: SymbolId
  path: DefPath
  name: String
  kind: SymKind
  vis: DeclVis
  pkg: String
  parent: Option[SymbolId]
  bare: Bool
  span: Span
}

/// What the resolver knows of a package other than its declarations: the
/// packages it re-exports (`pub use P`, D309), which a whole import of it
/// reaches (D311).
pub record PackageInfo {
  name: String
  reexports: List[String]
}

/// Every declaration of every loaded package, and the interner that gives each
/// its `SymbolId`.  Lookups go through a `FileScope` (`resolveBare`,
/// `resolveQualified`); the table has no "find any declaration named x" entry
/// point, so no pass can reach a declaration the file cannot see (§4.4).
pub record DeclTable {
  interner: DefPathInterner
  decls: List[Decl]
  byName: Map[String, List[Int]]
  byId: Map[String, Int]
  packages: Map[String, PackageInfo]
}

pub func newDeclTable(interner: in DefPathInterner): DeclTable {
  DeclTable(interner = interner, decls = newList(), byName = newMap(), byId = newMap(), packages = newMap())
}

/// The declaration with id `id`, newest registration, or `None`.
pub func declOfId(tbl: in DeclTable, id: in SymbolId): Option[Decl] {
  match mapGet(tbl.byId, toString(id.id)) {
    case Some(ix) -> Some(value = tbl.decls[ix])
    case None -> None
  }
}

/// The re-export closure of `pkg`: the packages it re-exports, directly or
/// through their own re-exports.  `pkg` itself is not in it.
pub func reexportClosure(tbl: in DeclTable, pkg: in String): List[String] {
  val acc: List[String] = newList()
  val queue: List[String] = newList()
  queue.add(pkg)
  var qi = 0
  while qi < queue.count {
    match mapGet(tbl.packages, queue[qi]) {
      case Some(info) -> {
        for q in info.reexports {
          if q != pkg and not acc.contains(q) {
            acc.add(q)
            queue.add(q)
          }
        }
      }
      case None -> ()
    }
    qi = qi + 1
  }
  acc
}

/// How a file sees a package: through an import of the package itself, or only
/// through the re-export of one it imports whole.  A name seen the first way
/// shadows the same name seen the second way (§4.3, #8709).
pub union Reach {
  case ReachDirect(via: String)
  case ReachReexport(via: String)
}

/// A name a file binds to a declaration of another package by name: a
/// selective import, optionally renamed (`import P.{f as g}`), or an
/// `import extern` binding.
pub record NameBinding {
  local: String
  pkg: String
  origName: String
  via: String
  renamed: Bool
}

/// One file's import fsc (docs/70 §4.1, §4.3): what that file may name bare,
/// and which packages it may name qualified.
pub record FileScope {
  pkg: String
  fileId: Int
  path: String
  /// Package -> how this file's whole imports reach it (the package itself
  /// and, after it, everything it re-exports).
  whole: Map[String, Reach]
  /// Local name -> the selective or extern bindings of it.
  names: Map[String, List[NameBinding]]
  /// Selective imports as `<package>|<name>` keys, the names that make a
  /// declaration (and, for a union or enum, its cases) visible bare.
  selected: Map[String, String]
  /// Alias -> package, for `import P as A`.
  aliases: Map[String, String]
  /// Package -> the import that names it in any form, for qualified paths.
  directPkgs: Map[String, String]
}

/// What looking a name up produced.
pub union Resolution {
  /// One declaration.
  case RSymbol(id: SymbolId)
  /// An overload set: functions of one package that share a name, in
  /// registration order.
  case ROverloads(ids: List[SymbolId])
  /// The qualifier of a path is a package.
  case RPackage(pkg: String)
  /// The name is a member of a value or type, left to the checker (§4.5).
  case RDeferred
  /// No declaration: a diagnostic code and message.
  case RUnresolved(code: String, message: String)
}

/// A lookup in type position wants a type, in value position a value (a
/// function, value, constructor or case), in pattern head position a case, a
/// record or a type.
pub union NameUse {
  case UseType
  case UseValue
  case UsePatternHead
}
