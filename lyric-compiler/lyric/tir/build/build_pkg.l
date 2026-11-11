//! build_pkg.l - a whole package as TIR (docs/70 §6.2, §6.3): every function body
//! of a checked file built into a `TFnDecl`, with the declarations the bodies reach
//! and every type of the table, and the bodies that did not build listed by name.
//! Phase 4 backends consume `PackageBuild.pkg` and fall back per body on `failed`.
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Tir

/// A function body the builder could not build (an I0002 site): its name, its symbol when
/// the checker has one, and the reasons.
pub record FnBuildFailure {
  name: String
  sym: Option[SymbolId]
  messages: List[String]
}

/// The outcome of building a file.  `pkg.funcs` holds one `TFnDecl` per built function,
/// keyed by `TFnDecl.sym`; `pkg.symbols` every entry the built bodies reach and every
/// type entry of the table.  `names` maps a symbol's `id` to the key of the DefPath it
/// was interned from, for every symbol in `pkg` and every case; `cases` maps a union's or enum's `id`
/// to its case symbols in declaration order, a case's tag being its index.
pub record PackageBuild {
  pkg: TPackage
  failed: List[FnBuildFailure]
  total: Int
  built: Int
  names: Map[Int, String]
  cases: Map[Int, List[SymbolId]]
  /// Per kind, the nodes the builder has no case for, and where each kind was first met
  /// (`line:column`); the `--verify-ir` census reports them.
  uncovered: Map[String, Int]
  sites: Map[String, String]
}

/// The union and enum cases of the table by the `id` of their parent, in the order the
/// table declares them.
pub func caseSymbolsByParent(tbl: in SymbolTable): Map[Int, List[SymbolId]] {
  val res: Map[Int, List[SymbolId]] = newMap()
  for s in tbl.symbols {
    var parent: Option[SymbolId] = None
    var cname = ""
    match s.kind {
      case DKUnionCase(pid, uc) -> {
        parent = Some(value = pid)
        cname = uc.name
      }
      case DKEnumCase(pid, ec) -> {
        parent = Some(value = pid)
        cname = ec.name
      }
      case _ -> ()
    }
    match parent {
      case Some(pid) -> match caseSymbolId(tbl, s, pid, cname) {
        case Some(cid) -> {
          if not res.containsKey(pid.id) {
            res.add(pid.id, newList())
          }
          match mapGet(res, pid.id) {
            case Some(l) -> l.add(cid)
            case None -> ()
          }
        }
        case None -> ()
      }
      case None -> ()
    }
  }
  res
}

/// Build every function body of `file` that has one, each with a fresh `BuildEnv`
/// sharing one synthetic node counter, into a package named `name`.
pub func buildPackage(ctx: in TyConvCtx, tbl: in SymbolTable, file: in SourceFile, name: in String): PackageBuild {
  val funcs: List[TFnDecl] = newList()
  val syms: Map[Int, TSymEntry] = newMap()
  val failed: List[FnBuildFailure] = newList()
  var total = 0
  var built = 0
  val sums: Map[String, Int] = newMap()
  val sites: Map[String, String] = newMap()
  val counter: List[Int] = newList()
  counter.add(firstSynthNodeId())
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> match decl.body {
        case Some(_) -> {
          total = total + 1
          val env = newBuildEnvSharing(ctx, counter)
          match buildFnDecl(env, decl, tbl) {
            case Some(fd) -> {
              built = built + 1
              funcs.add(fd)
              if not syms.containsKey(fd.sym.id) {
                syms.add(fd.sym.id, ownFnEntry(fd))
              }
            }
            case None -> failed.add(FnBuildFailure(name = decl.name, sym = symTableFuncSymOf(tbl, decl), messages = env.errors))
          }
          for sk in mapKeys(env.syms) {
            match mapGet(env.syms, sk) {
              case Some(en) -> if not syms.containsKey(sk) { syms.add(sk, en) }
              case None -> ()
            }
          }
          for k in mapKeys(env.uncovered) {
            val add = match mapGet(env.uncovered, k) { case Some(n) -> n; case None -> 0 }
            val had = match mapGet(sums, k) { case Some(n) -> n; case None -> 0 }
            if sums.containsKey(k) {
              sums.remove(k)
            }
            sums.add(k, had + add)
          }
          for k in mapKeys(env.sites) {
            match mapGet(env.sites, k) {
              case Some(at) -> if not sites.containsKey(k) { sites.add(k, at) }
              case None -> ()
            }
          }
        }
        case None -> ()
      }
      case _ -> ()
    }
  }
  for te in typeEntries(tbl) {
    if not syms.containsKey(te.sym.id) {
      syms.add(te.sym.id, te)
    }
  }
  val entries: List[TSymEntry] = newList()
  val names: Map[Int, String] = newMap()
  for k in mapKeys(syms) {
    match mapGet(syms, k) {
      case Some(en) -> {
        entries.add(en)
        noteName(tbl, names, en.sym)
      }
      case None -> ()
    }
  }
  for fd in funcs {
    noteName(tbl, names, fd.sym)
  }
  val cases = caseSymbolsByParent(tbl)
  for pk in mapKeys(cases) {
    match mapGet(cases, pk) {
      case Some(l) -> {
        for cs in l {
          noteName(tbl, names, cs)
        }
      }
      case None -> ()
    }
  }
  PackageBuild(
    pkg = TPackage(name = name, symbols = entries, funcs = funcs),
    failed = failed,
    total = total,
    built = built,
    names = names,
    cases = cases,
    uncovered = sums,
    sites = sites
  )
}

func noteName(tbl: in SymbolTable, names: in Map[Int, String], sym: in SymbolId): Unit {
  if names.containsKey(sym.id) {
    return
  }
  match symTableDefPathKeyOf(tbl, sym) {
    case Some(k) -> names.add(sym.id, k)
    case None -> ()
  }
}
