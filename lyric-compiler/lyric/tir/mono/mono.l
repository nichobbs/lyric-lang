//! mono.l - Lyric.Tir.Mono: the driver of the TIR monomorphiser (docs/70 §7.2, §7.3, D500).
//!
//! `monoBundle` is the one entry point: it takes the built packages of a bundle (an entry
//! package and everything it imports as source) and the interner they share, and returns a bundle
//! in which nothing is generic.  It is a `Lyric.Tir` to `Lyric.Tir` pass: run
//! `Lyric.Tir.Verify` on its output (`verifyMonoBundle`).
package Lyric.Tir.Mono

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build
import Lyric.Tir.Verify

/// Whether `en` is the declaration of a generic type the pass replaces by instances.
func isGenericTypeEntry(en: in TSymEntry): Bool {
  val isType = match en.kind { case TSkType -> true; case _ -> false }
  isType and en.typeParamCount > 0
}

/// A symbol entry of a non-generic declaration as the pass leaves it: its types with generic
/// applications replaced by instances.
func mEntry(c: in MCtx, en: in TSymEntry): TSymEntry {
  val s = noSubst()
  val fs: List[TFieldSig] = newList()
  for f in en.fields {
    fs.add(TFieldSig(name = f.name, ty = mTy(c, s, f.ty), mutable = f.mutable))
  }
  val sg: Option[TSig] = match en.sig {
    case Some(g) -> Some(
      value = TSig(
        typeParamCount = g.typeParamCount,
        params = mParamTys(c, s, g.params),
        ret = mTy(c, s, g.ret),
        isAsync = g.isAsync
      )
    )
    case None -> None
  }
  val ty: Option[Ty] = match en.ty {
    case Some(t) -> Some(value = mTy(c, s, t))
    case None -> None
  }
  TSymEntry(
    sym = en.sym,
    kind = en.kind,
    typeParamCount = en.typeParamCount,
    sig = sg,
    fields = fs,
    ty = ty,
    mutable = en.mutable
  )
}

/// Whether the entry is dropped: the declaration of a generic type or function the pass
/// instantiates, or a case of a generic union.
func isReplaced(c: in MCtx, en: in TSymEntry): Bool {
  if isGenericTypeEntry(en) {
    return true
  }
  match mapGet(c.decls, en.sym.id) {
    case Some(d) -> if d.typeParams.count > 0 { return true }
    case None -> ()
  }
  match mapGet(c.caseParent, en.sym.id) {
    case Some(parent) -> match mapGet(c.entries, parent.id) {
      case Some(pe) -> isGenericTypeEntry(pe)
      case None -> false
    }
    case None -> false
  }
}

func newMCtx(interner: in DefPathInterner, pkgs: in List[PackageBuild]): MCtx {
  val c = MCtx(
    interner = interner,
    decls = newMap(),
    entries = newMap(),
    cases = newMap(),
    caseParent = newMap(),
    insts = newMap(),
    instList = newList(),
    outSyms = newList(),
    outFns = newList(),
    outNames = newMap(),
    outCases = newMap(),
    work = newList(),
    diags = newList(),
    unresolved = newMap(),
    nextNode = newList()
  )
  c.nextNode.add(firstInstanceNodeId())
  for pb in pkgs {
    for f in pb.pkg.funcs {
      if not c.decls.containsKey(f.sym.id) {
        c.decls.add(f.sym.id, f)
      }
    }
    for en in pb.pkg.symbols {
      if not c.entries.containsKey(en.sym.id) {
        c.entries.add(en.sym.id, en)
      }
    }
    for pk in mapKeys(pb.cases) {
      match mapGet(pb.cases, pk) {
        case Some(cs) -> if not c.cases.containsKey(pk) {
          c.cases.add(pk, cs)
          for cs1 in cs {
            c.caseParent.add(cs1.id, SymbolId(id = pk))
          }
        }
        case None -> ()
      }
    }
  }
  c
}

/// Produce the body of every instance asked for, and of every instance those ask for.
func drainWork(c: in MCtx): Unit {
  var i = 0
  while i < c.work.count {
    val p = c.work[i]
    val s = Subst(owner = p.generic.sym, args = p.args, fresh = true)
    c.outFns.add(mFnDecl(c, s, p.inst, p.generic))
    i = i + 1
  }
}

/// `bundle` with nothing generic left.  A non-generic function is rewritten in place; a generic one
/// is dropped and replaced by the instances its callers ask for.  The instances of every package are
/// the last package of the result.  A generic use the bundle cannot instantiate (its declaration did
/// not build) stays as written and is counted in `unresolved`.
pub func monoBundle(interner: in DefPathInterner, bundle: in List[PackageBuild]): MonoResult {
  val c = newMCtx(interner, bundle)
  val out: List[PackageBuild] = newList()
  for pb in bundle {
    val fns: List[TFnDecl] = newList()
    for f in pb.pkg.funcs {
      if f.typeParams.count == 0 {
        fns.add(mFnDecl(c, noSubst(), f.sym, f))
      }
    }
    val syms: List[TSymEntry] = newList()
    for en in pb.pkg.symbols {
      if not isReplaced(c, en) {
        syms.add(mEntry(c, en))
      }
    }
    val cases: Map[Int, List[SymbolId]] = newMap()
    for pk in mapKeys(pb.cases) {
      val generic = match mapGet(c.entries, pk) { case Some(pe) -> isGenericTypeEntry(pe); case None -> false }
      if not generic {
        match mapGet(pb.cases, pk) {
          case Some(cs) -> cases.add(pk, cs)
          case None -> ()
        }
      }
    }
    out.add(
      PackageBuild(
        pkg = TPackage(name = pb.pkg.name, symbols = syms, funcs = fns),
        failed = pb.failed,
        total = pb.total,
        built = pb.built,
        names = pb.names,
        cases = cases,
        uncovered = pb.uncovered,
        sites = pb.sites
      )
    )
  }
  drainWork(c)
  out.add(
    PackageBuild(
      pkg = TPackage(name = instancesPackageName(), symbols = c.outSyms, funcs = c.outFns),
      failed = newList(),
      total = c.outFns.count,
      built = c.outFns.count,
      names = c.outNames,
      cases = c.outCases,
      uncovered = newMap(),
      sites = newMap()
    )
  )
  MonoResult(pkgs = out, instances = c.instList, diags = c.diags, unresolved = c.unresolved)
}

/// The instance of `generic` at `args` in `r`, if the pass made one: the table the code generator
/// maps between a generic and its instances with.
pub func instanceOf(r: in MonoResult, generic: in SymbolId, args: in List[Ty]): Option[SymbolId] {
  for i in r.instances {
    if symbolIdEq(i.generic, generic) and tyListEq(i.args, args) {
      return Some(value = i.inst)
    }
  }
  None
}

/// Verify every package of `r` (docs/70 §6.4) with the others' declarations visible to it.  The
/// result is every broken rule, rendered with its package's name; it is empty when the pass's output
/// is well formed.
pub func verifyMonoBundle(r: in MonoResult): List[String] {
  val res: List[String] = newList()
  var i = 0
  while i < r.pkgs.count {
    val own: Map[Int, Bool] = newMap()
    for en in r.pkgs[i].pkg.symbols {
      own.add(en.sym.id, true)
    }
    val deps: List[TSymEntry] = newList()
    val seen: Map[Int, Bool] = newMap()
    var j = 0
    while j < r.pkgs.count {
      if j != i {
        for en in r.pkgs[j].pkg.symbols {
          if not own.containsKey(en.sym.id) and not seen.containsKey(en.sym.id) {
            seen.add(en.sym.id, true)
            deps.add(en)
          }
        }
      }
      j = j + 1
    }
    for d in verifyPackage(r.pkgs[i].pkg, deps) {
      res.add(renderVerifyDiag(r.pkgs[i].pkg.name, d))
    }
    i = i + 1
  }
  res
}
