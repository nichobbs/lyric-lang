//! resolve_alias.l - the `alias X = T` targets a file sees (docs/70 §4.4, #8752).
//!
//! `aliasTargetsFor` replaces the backends' own alias scans
//! (`TypeAliasResolve.projectAliasTargets`, `BareFuncRef.collectFuncAliasTargets`):
//! one table per file, from the declaration table, so the answer follows what the
//! file's imports reach.  A target is returned with its names qualified in the
//! scope that declares it: `alias Pick = T.Seed` under `import A.Two as T` gives
//! the target `A.Two.Seed`, never the first `Seed` any package declares.
package Lyric.Resolve

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols

func splitPackage(pkg: in String): List[String] {
  val parts: List[String] = newList()
  var start = 0
  var i = 0
  while i < pkg.length {
    if pkg.substring(i, 1) == "." {
      parts.add(pkg.substring(start, i - start))
      start = i + 1
    }
    i = i + 1
  }
  parts.add(pkg.substring(start, pkg.length - start))
  parts
}

// `path` with a leading rename spelled out: the head of `T.Seed` under
// `import A.Two as T`, or a bare name an `import A.Two.{Seed as S}` renames.
// `None` when the scope renames nothing in it.
func qualifyPathIn(fsc: in FileScope, path: in ModulePath): Option[ModulePath] {
  if path.segments.count == 0 {
    return None
  }
  if path.segments.count >= 2 {
    match mapGet(fsc.aliases, path.segments[0]) {
      case Some(pkg) -> {
        val segs = splitPackage(pkg)
        var i = 1
        while i < path.segments.count {
          segs.add(path.segments[i])
          i = i + 1
        }
        return Some(value = ModulePath(segments = segs, span = path.span))
      }
      case None -> return None
    }
  }
  match mapGet(fsc.names, path.segments[0]) {
    case Some(bs) -> {
      if bs.count == 1 and bs[0].renamed and bs[0].pkg != "extern" {
        val segs = splitPackage(bs[0].pkg)
        segs.add(bs[0].origName)
        return Some(value = ModulePath(segments = segs, span = path.span))
      }
      None
    }
    case None -> None
  }
}

func qualifyPath(scopes: in List[FileScope], path: in ModulePath): ModulePath {
  for fsc in scopes {
    match qualifyPathIn(fsc, path) {
      case Some(q) -> return q
      case None -> ()
    }
  }
  path
}

func qualifyTypeArg(scopes: in List[FileScope], a: in TypeArg): TypeArg {
  match a {
    case TAType(ty) -> TAType(ty = qualifyTypeExpr(scopes, ty))
    case TAValue(_) -> a
  }
}

func qualifyTypes(scopes: in List[FileScope], xs: in List[TypeExpr]): List[TypeExpr] {
  val res: List[TypeExpr] = newList()
  for x in xs {
    res.add(qualifyTypeExpr(scopes, x))
  }
  res
}

func qualifyTypeExpr(scopes: in List[FileScope], te: in TypeExpr): TypeExpr {
  val kind = match te.kind {
    case TRef(path) -> TRef(path = qualifyPath(scopes, path))
    case TGenericApp(head, args) -> {
      val qargs: List[TypeArg] = newList()
      for a in args {
        qargs.add(qualifyTypeArg(scopes, a))
      }
      TGenericApp(head = qualifyPath(scopes, head), args = qargs)
    }
    case TArray(size, element) -> TArray(
      size = qualifyTypeArg(scopes, size),
      element = qualifyTypeExpr(scopes, element)
    )
    case TSlice(element) -> TSlice(element = qualifyTypeExpr(scopes, element))
    case TRefined(underlying, range) -> TRefined(underlying = qualifyPath(scopes, underlying), range = range)
    case TTuple(types) -> TTuple(types = qualifyTypes(scopes, types))
    case TNullable(inner) -> TNullable(inner = qualifyTypeExpr(scopes, inner))
    case TFunction(parameters, retTy) -> TFunction(
      parameters = qualifyTypes(scopes, parameters),
      retTy = qualifyTypeExpr(scopes, retTy)
    )
    case TParen(inner) -> TParen(inner = qualifyTypeExpr(scopes, inner))
    case other -> other
  }
  TypeExpr(kind = kind, span = te.span, aliasName = te.aliasName)
}

// The scopes an alias target of package `pkg` resolves in: the consuming file's
// first, then the package's other files, for the checked package; the
// dependency's own scope for a dependency.
func declaringScopes(ctx: in ResolverContext, fsc: in FileScope, pkg: in String): List[FileScope] {
  val scopes: List[FileScope] = newList()
  if pkg == fsc.pkg {
    scopes.add(fsc)
    for s in ctx.scopes {
      scopes.add(s)
    }
  } else {
    match mapGet(ctx.depScopes, pkg) {
      case Some(s) -> scopes.add(s)
      case None -> ()
    }
  }
  scopes
}

func reachesAliasPackage(fsc: in FileScope, pkg: in String): Bool {
  fsc.directPkgs.containsKey(pkg) or fsc.whole.containsKey(pkg)
}

/// The `alias X = T` targets `fsc` can use, by the name the file spells: its
/// package's own aliases first, then the `pub` aliases of every package it
/// imports (whole, selectively, renamed or through a re-export), the first of a
/// name winning.  A parameterized alias, and one whose target is a type of its
/// own name, has no target here.
pub func aliasTargetsFor(ctx: in ResolverContext, fsc: in FileScope): Map[String, TypeExpr] {
  val targets: Map[String, TypeExpr] = newMap()
  var pass = 0
  while pass < 2 {
    for d in ctx.tbl.decls {
      match d.aliasTarget {
        case Some(target) -> {
          val own = d.pkg == fsc.pkg
          if (pass == 0) == own and (own or declCrossPackageVisible(d)) {
            val scopes = declaringScopes(ctx, fsc, d.pkg)
            if own or reachesAliasPackage(fsc, d.pkg) {
              if not targets.containsKey(d.name) {
                targets.add(d.name, qualifyTypeExpr(scopes, target))
              }
            }
            if not own {
              for entry in mapKeys(fsc.names) {
                match mapGet(fsc.names, entry) {
                  case Some(bs) -> {
                    for b in bs {
                      if b.renamed and b.pkg == d.pkg and b.origName == d.name and not targets.containsKey(b.local) {
                        targets.add(b.local, qualifyTypeExpr(scopes, target))
                      }
                    }
                  }
                  case None -> ()
                }
              }
            }
          }
        }
        case None -> ()
      }
    }
    pass = pass + 1
  }
  targets
}
