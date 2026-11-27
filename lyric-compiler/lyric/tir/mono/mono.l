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
  val ty: Option[Ty] = match en.ty { case Some(t) -> Some(value = mTy(c, s, t)); case None -> None }
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
    nextNode = newList(),
    cur = newList(),
    tainted = newMap()
  )
  c.nextNode.add(firstInstanceNodeId())
  c.cur.add(0)
  c.workDone.add(0)
  for pb in pkgs {
    for im in pb.pkg.impls {
      c.implDecls.add(im)
    }
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
  var i = c.workDone[0]
  while i < c.work.count {
    val p = c.work[i]
    val s = Subst(owner = p.origin.sym, args = p.args, fresh = true)
    c.outFns.add(mFnDecl(c, s, p.inst, p.origin))
    i = i + 1
    c.workDone[0] = i
  }
}

/// An `impl` block of a non-generic target as the pass leaves it: its target and interface arguments mapped, an
/// interface with arguments replaced by its instance (which also makes the instance's method entries), its members
/// as they are (a block with its own type parameters is instantiated by `instantiateImpls`).
func mImpl(c: in MCtx, im: in TImplDecl): TImplDecl {
  val s = noSubst()
  var iface = im.iface
  var args: List[Ty] = mTys(c, s, im.ifaceArgs)
  if args.count > 0 and not anyParam(args) {
    match instType(c, im.iface, args) {
      case Some(ii) -> {
        iface = ii
        args = newList()
        for m in ifaceMethodsOf(c, im.iface) {
          val _ = instIfaceMethod(c, im.iface, mTys(c, s, im.ifaceArgs), m)
        }
      }
      case None -> noteUnresolved(c, "generic interface impl")
    }
  }
  TImplDecl(
    sym = im.sym,
    typeParams = im.typeParams,
    target = mTy(c, s, im.target),
    iface = iface,
    ifaceArgs = args,
    members = im.members,
    span = im.span
  )
}

/// Binds the parameters of the impl `owner` by matching the pattern `pat` against the closed type `actual`: slot
/// `i` of `binds` is the type `TParam(owner, i)` stands for.  False when they do not match.
func matchImplTy(pat: in Ty, actual: in Ty, owner: in SymbolId, binds: in List[Option[Ty]]): Bool {
  match pat {
    case TParam(o, i) -> {
      if not symbolIdEq(o, owner) or i < 0 or i >= binds.count {
        return tyEq(pat, actual)
      }
      match binds[i] {
        case Some(b) -> tyEq(b, actual)
        case None -> {
          binds[i] = Some(value = actual)
          true
        }
      }
    }
    case TNamed(ps, pargs) -> match actual {
      case TNamed(asym, aargs) -> symbolIdEq(ps, asym) and
        matchImplTys(pargs, aargs, owner, binds)
      case _ -> false
    }
    case TTuple(pxs) -> match actual { case TTuple(axs) -> matchImplTys(pxs, axs, owner, binds); case _ -> false }
    case TNullable(pi) -> match actual { case TNullable(ai) -> matchImplTy(pi, ai, owner, binds); case _ -> false }
    case TSlice(pe) -> match actual { case TSlice(ae) -> matchImplTy(pe, ae, owner, binds); case _ -> false }
    case _ -> tyEq(pat, actual)
  }
}

func matchImplTys(ps: in List[Ty], xs: in List[Ty], owner: in SymbolId, binds: in List[Option[Ty]]): Bool {
  if ps.count != xs.count {
    return false
  }
  var i = 0
  while i < ps.count {
    if not matchImplTy(ps[i], xs[i], owner, binds) {
      return false
    }
    i = i + 1
  }
  true
}

/// Instantiates every generic `impl` block at each instance of its target type: the block's members are instantiated
/// at the arguments the target's instance binds, and an impl of the instance is recorded over the instance of the
/// target and the instance of the interface.  Runs to a fixpoint, since an instantiated member can ask for more
/// instances.
func instantiateImpls(c: in MCtx): Unit {
  var again = true
  while again {
    again = false
    var gi = 0
    while gi < c.implDecls.count {
      val im = c.implDecls[gi]
      if im.typeParams.count > 0 {
        match im.target {
          case TNamed(tsym, targs) -> {
            var k = 0
            while k < c.instList.count {
              val ii = c.instList[k]
              k = k + 1
              if symbolIdEq(ii.origin, tsym) and ii.args.count == targs.count {
                val binds: List[Option[Ty]] = newList()
                var q = 0
                while q < im.typeParams.count {
                  binds.add(None)
                  q = q + 1
                }
                val args: List[Ty] = newList()
                var ok = matchImplTys(targs, ii.args, im.sym, binds)
                for b in binds {
                  match b {
                    case Some(t) -> args.add(t)
                    case None -> {
                      ok = false
                    }
                  }
                }
                val key = symKey(c, im.sym) + "[" + tyKeys(c, args) + "]"
                if ok and not c.implDone.containsKey(key) {
                  c.implDone.add(key, true)
                  again = true
                  instantiateImpl(c, im, args, key)
                }
              }
            }
          }
          case _ -> {
            if not c.implDone.containsKey("#" + toString(im.sym.id)) {
              c.implDone.add("#" + toString(im.sym.id), true)
              noteUnresolved(c, "generic impl of a target that is not a named type")
            }
          }
        }
      }
      gi = gi + 1
    }
    drainWork(c)
  }
}

func instantiateImpl(c: in MCtx, im: in TImplDecl, args: in List[Ty], key: in String): Unit {
  val sub = Subst(owner = im.sym, args = args, fresh = false)
  val members: List[SymbolId] = newList()
  for m in im.members {
    match mapGet(c.decls, m.id) {
      case Some(d) -> if d.typeParams.count == args.count {
        match instFn(c, d, args) {
          case Some(i) -> members.add(i)
          case None -> ()
        }
      } else if d.typeParams.count < args.count {
        noteUnresolved(c, "impl member with fewer parameters than its impl")
      }
      case None -> noteUnresolved(c, "impl member without a declaration")
    }
  }
  var iface = im.iface
  val iargs = mTys(c, sub, im.ifaceArgs)
  if iargs.count > 0 {
    match instType(c, im.iface, iargs) {
      case Some(ii) -> {
        iface = ii
        for m in ifaceMethodsOf(c, im.iface) {
          val _ = instIfaceMethod(c, im.iface, iargs, m)
        }
      }
      case None -> noteUnresolved(c, "generic interface impl")
    }
  }
  val sym = internDefPathKey(c.interner, key)
  c.outNames.add(sym.id, key)
  c.outImpls.add(
    TImplDecl(
      sym = sym,
      typeParams = newList(),
      target = mTy(c, sub, im.target),
      iface = iface,
      ifaceArgs = if iface.id == im.iface.id { iargs } else { newList() },
      members = members,
      span = im.span
    )
  )
}

/// `bundle` with nothing generic left.  A non-generic function is rewritten in place; a generic one
/// is dropped and replaced by the instances its callers ask for.  The instances of every package are
/// the last package of the result.  A generic use the bundle cannot instantiate (its declaration did
/// not build) stays as written and is counted in `unresolved`.
pub func monoBundle(interner: in DefPathInterner, bundle: in List[PackageBuild]): MonoResult {
  val c = newMCtx(interner, bundle)
  val res: List[PackageBuild] = newList()
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
      val origin = match mapGet(c.entries, pk) { case Some(pe) -> isGenericTypeEntry(pe); case None -> false }
      if not origin {
        match mapGet(pb.cases, pk) {
          case Some(cs) -> cases.add(pk, cs)
          case None -> ()
        }
      }
    }
    val impls: List[TImplDecl] = newList()
    for im in pb.pkg.impls {
      if im.typeParams.count == 0 {
        impls.add(mImpl(c, im))
      }
    }
    res.add(
      PackageBuild(
        pkg = TPackage(name = pb.pkg.name, symbols = syms, funcs = fns, impls = impls),
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
  instantiateImpls(c)
  res.add(
    PackageBuild(
      pkg = TPackage(name = instancesPackageName(), symbols = c.outSyms, funcs = c.outFns, impls = c.outImpls),
      failed = newList(),
      total = c.outFns.count,
      built = c.outFns.count,
      names = c.outNames,
      cases = c.outCases,
      uncovered = newMap(),
      sites = newMap()
    )
  )
  MonoResult(pkgs = res, instances = c.instList, diags = c.diags, unresolved = c.unresolved, tainted = c.tainted)
}

/// The instance of `generic` at `args` in `r`, if the pass made one: the table the code generator
/// maps between a generic and its instances with.
pub func instanceOf(r: in MonoResult, origin: in SymbolId, args: in List[Ty]): Option[SymbolId] {
  for i in r.instances {
    if symbolIdEq(i.origin, origin) and tyListEq(i.args, args) {
      return Some(value = i.inst)
    }
  }
  None
}

/// The verifier's verdict on a mono bundle: `failures` are broken rules in a function whose generic
/// callees all resolved, `tolerated` counts the broken rules in functions that call a generic with no
/// declaration in the bundle (`MonoResult.tainted`), whose generic signature the rewritten call cannot match.
pub record MonoVerify {
  failures: List[String]
  tolerated: Int
}

/// Verify every package of `r` (docs/70 §6.4) with the others' declarations visible to it.  Empty
/// `failures` means the pass's output is well formed.
pub func verifyMonoBundle(r: in MonoResult): MonoVerify {
  val res: List[String] = newList()
  var tolerated = 0
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
      if r.tainted.containsKey(d.fnSym.id) {
        tolerated = tolerated + 1
      } else {
        res.add(renderVerifyDiag(r.pkgs[i].pkg.name, d))
      }
    }
    i = i + 1
  }
  MonoVerify(failures = res, tolerated = tolerated)
}
