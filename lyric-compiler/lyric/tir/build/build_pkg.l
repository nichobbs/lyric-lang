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
import Lyric.Iface

/// A function body the builder could not build (an I0002 site): its name, its symbol when
/// the checker has one, and the reasons.
pub record FnBuildFailure {
  /// `f` for a top-level function, `Owner.f` for a member, `impl.f` for an `impl` member.
  name: String
  sym: Option[SymbolId]
  messages: List[String]
  /// The key of the symbol's DefPath (`pkg|segments`) when it has one: the name a consumer can
  /// match against `PackageBuild.names` without the display `name`.
  path: Option[String] = None
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

/// Fold the declarations, uncovered counts and sites of a finished `env` into the package's.
func absorbEnv(
  env: in BuildEnv, syms: in Map[Int, TSymEntry], sums: in Map[String, Int], sites: in Map[String, String]
): Unit {
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
            case None -> {
              val fsym = symTableFuncSymOf(tbl, decl)
              failed.add(FnBuildFailure(name = decl.name, sym = fsym, messages = env.errors, path = defPathKey(tbl, fsym)))
            }
          }
          absorbEnv(env, syms, sums, sites)
        }
        case None -> ()
      }
      case _ -> ()
    }
  }
  val pkgName = modulePathJoin(file.packageDecl.path.segments)
  val memberFns: List[TFnDecl] = newList()
  val sigOnlyFns: List[TFnDecl] = newList()
  val entryFns: Map[Int, Bool] = newMap()
  for site in memberSites(ctx, tbl, file) {
    total = total + 1
    val env = newBuildEnvSharing(ctx, counter)
    match buildMember(env, tbl, pkgName, site) {
      case Some(fd) -> {
        built = built + 1
        funcs.add(fd)
        memberFns.add(fd)
        // Two sites can share a symbol (a stub impl shares its member's span), and a map add of a
        // key already present would fail.
        if site.isEntry and not entryFns.containsKey(fd.sym.id) {
          entryFns.add(fd.sym.id, true)
        }
      }
      case None -> {
        val msym = memberSymOf(tbl, pkgName, site)
        failed.add(FnBuildFailure(name = site.name, sym = msym, messages = env.errors, path = defPathKey(tbl, msym)))
        // The member still has a signature: describe it by its declaration, so a call site's
        // instantiated signature is not taken for it.
        match buildMemberSig(newBuildEnvSharing(ctx, counter), tbl, pkgName, site) {
          case Some(sd) -> {
            sigOnlyFns.add(sd)
            if site.isEntry and not entryFns.containsKey(sd.sym.id) {
              entryFns.add(sd.sym.id, true)
            }
          }
          case None -> ()
        }
      }
    }
    absorbEnv(env, syms, sums, sites)
  }
  // A member the package builds is described by its declaration, not by the first call site's
  // signature: a call of a member of a generic type sees the receiver's arguments, not the
  // owner's parameters (D579), and a signature that cannot be converted leaves no entry.  The
  // kind a call recorded is kept: a call of a protected type's `func` is recorded as an entry.
  val memberEntries: Map[Int, TSymEntry] = newMap()
  val described: List[TFnDecl] = newList()
  for fd in memberFns {
    described.add(fd)
  }
  for fd in sigOnlyFns {
    described.add(fd)
  }
  for fd in described {
    if not memberEntries.containsKey(fd.sym.id) {
      val own = ownFnEntry(fd)
      val callKind: TSymKind = match mapGet(syms, fd.sym.id) { case Some(prev) -> prev.kind; case None -> TSkFunc }
      val kind: TSymKind = if entryFns.containsKey(fd.sym.id) { TSkEntry } else { callKind }
      memberEntries.add(
        fd.sym.id,
        TSymEntry(
          sym = own.sym,
          kind = kind,
          typeParamCount = own.typeParamCount,
          sig = own.sig,
          fields = own.fields,
          ty = own.ty,
          mutable = own.mutable
        )
      )
    }
  }
  val all: Map[Int, TSymEntry] = newMap()
  for sk in mapKeys(syms) {
    match mapGet(syms, sk) {
      case Some(en) -> if not memberEntries.containsKey(sk) { all.add(sk, en) }
      case None -> ()
    }
  }
  for mk in mapKeys(memberEntries) {
    match mapGet(memberEntries, mk) {
      case Some(me) -> all.add(mk, me)
      case None -> ()
    }
  }
  for te in typeEntries(tbl) {
    if not all.containsKey(te.sym.id) {
      all.add(te.sym.id, te)
    }
  }
  val entries: List[TSymEntry] = newList()
  val names: Map[Int, String] = newMap()
  for k in mapKeys(all) {
    match mapGet(all, k) {
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

func defPathKey(tbl: in SymbolTable, sym: in Option[SymbolId]): Option[String] {
  match sym {
    case Some(s) -> symTableDefPathKeyOf(tbl, s)
    case None -> None
  }
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

func declaresDefault(fn: in FunctionDecl): Bool {
  for p in fn.params {
    if isSome(p.dflt) {
      return true
    }
  }
  false
}

func entriesOf(env: in BuildEnv): List[TSymEntry] {
  val es: List[TSymEntry] = newList()
  for k in mapKeys(env.syms) {
    match mapGet(env.syms, k) {
      case Some(e) -> es.add(e)
      case None -> ()
    }
  }
  es
}

func noteDefaults(tbl: in SymbolTable, acc: in Map[String, Map[String, IfDefault]], env: in BuildEnv, fd: in TFnDecl): Unit {
  val byName: Map[String, IfDefault] = newMap()
  val es = entriesOf(env)
  for p in fd.params {
    match p.dflt {
      case Some(d) -> if not byName.containsKey(p.local.name) {
        byName.add(p.local.name, IfDefault(expr = d, entries = es))
      }
      case None -> ()
    }
  }
  if byName.count == 0 {
    return
  }
  match defPathKey(tbl, Some(value = fd.sym)) {
    case Some(k) -> if not acc.containsKey(k) { acc.add(k, byName) }
    case None -> ()
  }
}

/// The defaults of the fields of the non-generic record `decl`, by the record's DefPath key
/// and then the field's name: a construction that leaves a field out takes its default.
func noteFieldDefaults(
  ctx: in TyConvCtx,
  tbl: in SymbolTable,
  pkg: in String,
  counter: in List[Int],
  acc: in Map[String, Map[String, IfDefault]],
  decl: in RecordDecl,
): Unit {
  if decl.generics.isSome() {
    return
  }
  val built: List[IfDefault] = newList()
  val names: List[String] = newList()
  val env = newBuildEnvSharing(ctx, counter)
  pushScope(env)
  for m in decl.members {
    match m {
      case RMField(fd) -> match fd.dflt {
        case Some(dx) -> match buildExpr(env, dx) {
          case Some(t) -> {
            names.add(fd.name)
            built.add(IfDefault(expr = t, entries = newList()))
          }
          case None -> ()
        }
        case None -> ()
      }
      case _ -> ()
    }
  }
  if names.count == 0 {
    return
  }
  val es = entriesOf(env)
  val byName: Map[String, IfDefault] = newMap()
  var i = 0
  while i < names.count {
    if not byName.containsKey(names[i]) {
      byName.add(names[i], IfDefault(expr = built[i].expr, entries = es))
    }
    i = i + 1
  }
  match defPathKey(tbl, Some(value = symTableTypeSymbolId(tbl, pkg, decl.name))) {
    case Some(k) -> if not acc.containsKey(k) { acc.add(k, byName) }
    case None -> ()
  }
}

/// The default of every parameter and record field that declares one, built for a package
/// interface (docs/70 section 9.2, D482): the parameters of a package's functions and of its
/// methods, by the function's DefPath key and then the parameter's name, and the fields of its
/// non-generic records, by the record's key and the field's name, each with the declarations it
/// names.  A default is built from the package's own checker tables, so it is typed and its names
/// are resolved; one that does not build is left out and counted in no census (the consumer counts
/// the call that needs it).
pub func buildPackageDefaults(ctx: in TyConvCtx, tbl: in SymbolTable, file: in SourceFile): Map[String, Map[String, IfDefault]] {
  val acc: Map[String, Map[String, IfDefault]] = newMap()
  val counter: List[Int] = newList()
  counter.add(firstSynthNodeId())
  val pkgName = modulePathJoin(file.packageDecl.path.segments)
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> if declaresDefault(decl) {
        val env = newBuildEnvSharing(ctx, counter)
        match buildFnDefaultsDecl(env, decl, tbl) {
          case Some(fd) -> noteDefaults(tbl, acc, env, fd)
          case None -> ()
        }
      }
      case IRecord(decl) -> noteFieldDefaults(ctx, tbl, pkgName, counter, acc, decl)
      case _ -> ()
    }
  }
  for site in memberSites(ctx, tbl, file) {
    if declaresDefault(site.fn) {
      val env = newBuildEnvSharing(ctx, counter)
      match buildMemberDefaults(env, tbl, pkgName, site) {
        case Some(fd) -> noteDefaults(tbl, acc, env, fd)
        case None -> ()
      }
    }
  }
  acc
}
