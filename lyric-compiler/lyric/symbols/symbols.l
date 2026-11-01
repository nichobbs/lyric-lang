//! symbols.l - Lyric.Symbols
//!
//! The identity of a declaration (docs/70 §4.2): its `DefPath`, the stable
//! path an interface artifact records, and the `SymbolId` a compilation
//! interns it to.  The resolver (`Lyric.Resolve`) and the type checker
//! (`Lyric.TypeChecker`) share one `DefPathInterner`, so a declaration is
//! one id wherever either stage meets it.
//!
//! This package is a leaf: it depends on nothing else of the compiler, so
//! the resolver can run before the checker and the checker can still name
//! the ids it resolves.
package Lyric.Symbols

import Std.Core
import Std.Collections

/// A declaration's identity within one compilation: its `DefPath`
/// (`defPathKey`) interned by `internDefPath`, dense from 1.  Two
/// registrations of one declaration (a package reached both as a restored
/// dependency and from source) intern to the same id.  A declaration with no
/// package, and the checker's built-in types, take ids no DefPath names.
@stable(since = "0.1")
pub record SymbolId {
  id: Int
}

/// The stable path of a declaration (docs/70 §4.2): its declaring package
/// and its path inside it.  A type is `Pkg::Name`; an extern type with a host
/// name is the host name under the `extern` root, so every extern type naming
/// one host type is one declaration.  A function is `Pkg::name(P1,P2)` (its
/// parameter types as written, the overload discriminator, D313); a method
/// adds its type as a segment, `Pkg::Type::name(P1)`.  The key is what an
/// interface artifact records.
pub record DefPath {
  pkg: String
  segments: List[String]
}

/// `Pkg::A::B`: the rendered form of `p`, and the key it is interned under.
pub func defPathKey(p: in DefPath): String {
  var key = p.pkg
  for s in p.segments {
    key = key + "::" + s
  }
  key
}

/// The DefPath of the declaration `name` that package `pkg` declares at the
/// top level.
pub func topDefPath(pkg: in String, name: in String): DefPath {
  val segs: List[String] = newList()
  segs.add(name)
  DefPath(pkg = pkg, segments = segs)
}

/// The DefPath of the type `name` that package `pkg` declares.
pub func typeDefPath(pkg: in String, name: in String): DefPath {
  topDefPath(pkg, name)
}

/// The DefPath of the member `name` of the declaration at `parent` (a union
/// case, a method, a field): `parent` with one more segment.
pub func memberDefPath(parent: in DefPath, name: in String): DefPath {
  val segs: List[String] = newList()
  for s in parent.segments {
    segs.add(s)
  }
  segs.add(name)
  DefPath(pkg = parent.pkg, segments = segs)
}

/// The DefPath of an extern type bound to the host type `hostName`.
pub func externTypeDefPath(hostName: in String): DefPath {
  topDefPath("extern", hostName)
}

pub func symbolIdEq(a: in SymbolId, b: in SymbolId): Bool {
  a.id == b.id
}

/// Interns DefPath keys to dense `SymbolId`s.  One per compilation, shared by
/// every stage that mints or reads ids.
pub record DefPathInterner {
  ids: Map[String, Int]
  keys: List[String]
}

pub func newDefPathInterner(): DefPathInterner {
  DefPathInterner(ids = newMap(), keys = newList())
}

/// The `SymbolId` of the declaration at `path`: the same id for every
/// registration of it in this compilation (docs/70 §4.2).
pub func internDefPath(it: in DefPathInterner, path: in DefPath): SymbolId {
  val key = defPathKey(path)
  match mapGet(it.ids, key) {
    case Some(id) -> SymbolId(id = id)
    case None -> {
      it.keys.add(key)
      val id = it.keys.count
      it.ids.add(key, id)
      SymbolId(id = id)
    }
  }
}

/// A fresh `SymbolId` for a declaration with no DefPath: one registered with
/// no package (the checker's flat `checkWithImports` form), whose identity is
/// its registration.
pub func freshSymbolId(it: in DefPathInterner): SymbolId {
  it.keys.add("")
  SymbolId(id = it.keys.count)
}

/// The DefPath key `id` was interned from, or `None` for an id no DefPath
/// names (a fresh id, or a built-in type's).
pub func defPathKeyOf(it: in DefPathInterner, id: in SymbolId): Option[String] {
  if id.id < 1 or id.id > it.keys.count {
    return None
  }
  val key = it.keys[id.id - 1]
  if key.length == 0 {
    None
  } else {
    Some(value = key)
  }
}

/// The id interned from `key`, or `None` when no declaration was interned
/// under it.
pub func symbolIdOfKey(it: in DefPathInterner, key: in String): Option[SymbolId] {
  match mapGet(it.ids, key) {
    case Some(id) -> Some(value = SymbolId(id = id))
    case None -> None
  }
}
