//! typechecker_exportvis.l: T0212, a `pub` or `internal` declaration whose
//! signature names a type of its own package that is less visible than
//! itself (#7214, docs/70 §9.3).
//!
//! Every type a declaration exposes is part of what a consumer must be able
//! to name: a `pub` function returning a package-private type compiles in
//! its own package, then leaves every consumer of the built library with a
//! signature that names a type its interface does not carry.  The rule is
//! applied where the declaration is written, against the declaration's
//! effective visibility: a method in a type body, and a dot-named function
//! `func T.m`, reach no further than `T` itself (language reference §3.1),
//! so their signatures are checked against the lesser of the two.
//!
//! Checked positions: function and method parameters and return types,
//! record and exposed-record fields, union case payloads, interface method
//! signatures, a distinct type's underlying type, a type alias's target, and
//! the annotated type of a `pub val`.  An opaque type's fields and a
//! protected type's state are its own representation, never exposed, and are
//! not checked.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

/// `0` package-private, `1` internal, `2` pub.
func visibilityRank(v: in Option[Visibility]): Int {
  match v {
    case Some(VisPub(_)) -> 2
    case Some(VisInternal(_)) -> 1
    case None -> 0
  }
}

func visibilityWord(rank: in Int): String {
  if rank >= 2 {
    "pub"
  } else if rank == 1 {
    "internal"
  } else {
    "package-private"
  }
}

func exportVisMinRank(a: in Int, b: in Int): Int = if a < b { a } else { b }

func itemRank(item: in Item): Int {
  val r = visibilityRank(item.visibility)
  match item.kind {
    case IFunc(fd) -> if r > visibilityRank(fd.visibility) { r } else { visibilityRank(fd.visibility) }
    case _ -> r
  }
}

/// The visibility of every type the package declares, by name.
func declaredTypeRanks(items: in List[Item]): Map[String, Int] {
  val ranks: Map[String, Int] = newMap()
  for item in items {
    val r = itemRank(item)
    val name = match item.kind {
      case IRecord(d) -> d.name
      case IExposedRec(d) -> d.name
      case IUnion(d) -> d.name
      case IEnum(d) -> d.name
      case IOpaque(d) -> d.name
      case IProtected(d) -> d.name
      case IInterface(d) -> d.name
      case IDistinctType(d) -> d.name
      case ITypeAlias(d) -> d.name
      case _ -> ""
    }
    if name.length > 0 and not ranks.containsKey(name) {
      ranks.add(name, r)
    }
  }
  ranks
}

record ExportCheck {
  pkg: String
  ranks: Map[String, Int]
  diag: List[Diagnostic]
}

func genericNamesOf(g: in Option[GenericParams], into: in List[String]): Unit {
  match g {
    case Some(gp) -> {
      for p in gp.params {
        match p {
          case GPType(n, _) -> into.add(n)
          case GPValue(n, _, _) -> into.add(n)
        }
      }
    }
    case None -> ()
  }
}

func exportVisListHas(xs: in List[String], s: in String): Bool {
  for x in xs {
    if x == s {
      return true
    }
  }
  false
}

/// The declared type a path names when it is one of this package's own
/// types: a bare name, or one qualified by the package itself.
func ownTypeName(ec: in ExportCheck, path: in ModulePath, generics: in List[String]): String {
  val n = path.segments.count
  if n == 0 {
    return ""
  }
  val last = path.segments[n - 1]
  if n == 1 {
    if exportVisListHas(generics, last) {
      return ""
    }
    return last
  }
  val owner: List[String] = newList()
  var i = 0
  while i < n - 1 {
    owner.add(path.segments[i])
    i = i + 1
  }
  if modulePathJoin(owner) == ec.pkg {
    last
  } else {
    ""
  }
}

func checkExportedPath(
  ec: in ExportCheck,
  path: in ModulePath,
  rank: in Int,
  what: in String,
  generics: in List[String],
  span: in Span,
): Unit {
  val name = ownTypeName(ec, path, generics)
  if name.length == 0 {
    return
  }
  match mapGet(ec.ranks, name) {
    case Some(tr) -> if tr < rank {
      ec.diag.add(
        errorDiagnostic(
          "T0212",
          visibilityWord(rank) + " " + what + " names the " + visibilityWord(tr) + " type '" + name + "'; mark '" + name +
            "' `" +
            visibilityWord(rank) +
            "` or narrow the declaration's visibility",
          span
        )
      )
    }
    case None -> ()
  }
}

func checkExportedType(
  ec: in ExportCheck, te: in TypeExpr, rank: in Int, what: in String, generics: in List[String]
): Unit {
  if rank == 0 {
    return
  }
  match te.kind {
    case TRef(path) -> checkExportedPath(ec, path, rank, what, generics, te.span)
    case TGenericApp(head, args) -> {
      checkExportedPath(ec, head, rank, what, generics, te.span)
      for a in args {
        match a {
          case TAType(t) -> checkExportedType(ec, t, rank, what, generics)
          case TAValue(_) -> ()
        }
      }
    }
    case TArray(_, el) -> checkExportedType(ec, el, rank, what, generics)
    case TSlice(el) -> checkExportedType(ec, el, rank, what, generics)
    case TRefined(u, _) -> checkExportedPath(ec, u, rank, what, generics, te.span)
    case TTuple(ts) -> {
      for t in ts {
        checkExportedType(ec, t, rank, what, generics)
      }
    }
    case TNullable(inner) -> checkExportedType(ec, inner, rank, what, generics)
    case TFunction(ps, r) -> {
      for p in ps {
        checkExportedType(ec, p, rank, what, generics)
      }
      checkExportedType(ec, r, rank, what, generics)
    }
    case TParen(inner) -> checkExportedType(ec, inner, rank, what, generics)
    case _ -> ()
  }
}

func checkExportedSignature(
  ec: in ExportCheck,
  name: in String,
  g: in Option[GenericParams],
  outer: in List[String],
  params: in List[Param],
  ret: in Option[TypeExpr],
  rank: in Int,
): Unit {
  if rank == 0 {
    return
  }
  val generics: List[String] = newList()
  for o in outer {
    generics.add(o)
  }
  genericNamesOf(g, generics)
  val what = "function '" + name + "'"
  for p in params {
    checkExportedType(ec, p.ty, rank, what, generics)
  }
  match ret {
    case Some(rt) -> checkExportedType(ec, rt, rank, what, generics)
    case None -> ()
  }
}

/// A dot-named function `func T.m` reaches no further than `T`.
func dotReceiverRank(ec: in ExportCheck, name: in String, rank: in Int): Int {
  match name.indexOf(".") {
    case Some(dot) -> if dot > 0 {
      match mapGet(ec.ranks, name.substring(0, dot)) {
        case Some(tr) -> exportVisMinRank(rank, tr)
        case None -> rank
      }
    } else {
      rank
    }
    case None -> rank
  }
}

func checkRecordMembers(ec: in ExportCheck, d: in RecordDecl, rank: in Int): Unit {
  val generics: List[String] = newList()
  genericNamesOf(d.generics, generics)
  for m in d.members {
    match m {
      case RMField(f) -> checkExportedType(ec, f.ty, rank, "record '" + d.name + "' field '" + f.name + "'", generics)
      case RMFunc(fd) -> checkExportedSignature(
        ec,
        d.name + "." + fd.name,
        fd.generics,
        generics,
        fd.params,
        fd.ret,
        exportVisMinRank(rank, visibilityRank(fd.visibility))
      )
      case RMInvariant(_) -> ()
    }
  }
}

func valWhat(p: in Pattern): String {
  match p.kind {
    case PBinding(name, _) -> "val '" + name + "'"
    case _ -> "val"
  }
}

/// T0212 over the items of package `pkg` (docs/70 §9.3).
pub func checkExportedSignatureVisibility(pkg: in String, items: in List[Item], diag: in List[Diagnostic]): Unit {
  val ec = ExportCheck(pkg = pkg, ranks = declaredTypeRanks(items), diag = diag)
  val none: List[String] = newList()
  for item in items {
    val rank = itemRank(item)
    if rank > 0 {
      match item.kind {
        case IFunc(fd) -> checkExportedSignature(
          ec,
          fd.name,
          fd.generics,
          none,
          fd.params,
          fd.ret,
          dotReceiverRank(ec, fd.name, rank)
        )
        case IRecord(d) -> checkRecordMembers(ec, d, rank)
        case IExposedRec(d) -> checkRecordMembers(ec, d, rank)
        case IUnion(d) -> {
          val generics: List[String] = newList()
          genericNamesOf(d.generics, generics)
          for c in d.cases {
            for f in c.fields {
              match f {
                case UFNamed(_, t, _) -> checkExportedType(ec, t, rank, "union '" + d.name + "' case '" + c.name + "'", generics)
                case UFPos(t, _) -> checkExportedType(ec, t, rank, "union '" + d.name + "' case '" + c.name + "'", generics)
              }
            }
          }
        }
        case IInterface(d) -> {
          val generics: List[String] = newList()
          genericNamesOf(d.generics, generics)
          for m in d.members {
            match m {
              case IMSig(s) -> checkExportedSignature(ec, d.name + "." + s.name, s.generics, generics, s.params, s.ret, rank)
              case IMFunc(fd) -> checkExportedSignature(
                ec,
                d.name + "." + fd.name,
                fd.generics,
                generics,
                fd.params,
                fd.ret,
                rank
              )
              case IMAssoc(_) -> ()
            }
          }
        }
        case IDistinctType(d) -> {
          val generics: List[String] = newList()
          genericNamesOf(d.generics, generics)
          checkExportedType(ec, d.underlying, rank, "type '" + d.name + "'", generics)
        }
        case ITypeAlias(d) -> {
          val generics: List[String] = newList()
          genericNamesOf(d.generics, generics)
          checkExportedType(ec, d.rhs, rank, "alias '" + d.name + "'", generics)
        }
        case IVal(d) -> match d.ty {
          case Some(t) -> checkExportedType(ec, t, rank, valWhat(d.pattern), none)
          case None -> ()
        }
        case IConst(d) -> checkExportedType(ec, d.ty, rank, "const '" + d.name + "'", none)
        case _ -> ()
      }
    }
  }
}
