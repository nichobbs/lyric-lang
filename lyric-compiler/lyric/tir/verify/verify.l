//! verify.l - Lyric.Tir.Verify: the TIR verifier (docs/70 §6.4, D323).
//!
//! `verifyPackage` checks a TIR package and reports I0003 for every node that
//! breaks a rule: types closed, call arguments equal to the callee's
//! parameters under the instantiation, symbols and locals defined, branch and
//! arm types equal to the node's, assignments to mutable places, NodeIds
//! unique.  A pass runs it on its output, so a wrong type is reported at the
//! pass that produced it, not as a backend failure at run time.
package Lyric.Tir.Verify

import Std.Core
import Std.Collections
import Lyric.Symbols
import Lyric.Tir

/// One broken rule at one node.  `rule` is a short stable name (`closed-type`,
/// `call-arg-type`, ...) so tests and tooling can match on it.
pub record VerifyDiag {
  node: NodeId
  /// The function being verified (its `SymbolId`), so a diagnostic about a
  /// parameter or the return type, which has no node of its own, still says
  /// where it is.
  fnSym: SymbolId
  rule: String
  message: String
}

/// `I0003: pass <pass> produced an ill-formed node #<id>: <rule>: <message>`.
pub func renderVerifyDiag(pass: in String, d: in VerifyDiag): String {
  "I0003: pass " + pass + " produced an ill-formed node #" + toString(d.node.id) + " (in function #" +
    toString(d.fnSym.id) +
    "): " +
    d.rule +
    ": " +
    d.message
}

record Subst {
  owner: SymbolId
  args: List[Ty]
}

record LambdaFrame {
  outer: Map[Int, Bool]
  captured: Map[Int, Bool]
}

record Ctx {
  diags: List[VerifyDiag]
  seenNodes: Map[Int, Bool]
  allLocals: Map[Int, Bool]
  syms: Map[Int, TSymEntry]
  fnSym: SymbolId
  tpCount: Int
  locals: Map[Int, LocalDecl]
  /// Locals whose scope is open: a binding leaves it when its block, arm,
  /// loop, closure or quantifier ends, while `locals` keeps the declaration.
  live: Map[Int, Bool]
  scopeIds: List[Int]
  frames: List[LambdaFrame]
}

func report(c: in Ctx, id: in NodeId, rule: in String, msg: in String): Unit {
  c.diags.add(VerifyDiag(node = id, fnSym = c.fnSym, rule = rule, message = msg))
}

func lookupSym(c: in Ctx, s: in SymbolId): Option[TSymEntry] {
  mapGet(c.syms, s.id)
}

func isTrue(m: in Map[Int, Bool], k: in Int): Bool {
  match mapGet(m, k) {
    case Some(v) -> v
    case None -> false
  }
}

func requireSym(c: in Ctx, id: in NodeId, s: in SymbolId, what: in String): Unit {
  if isBuiltinSymbol(s) {
    return
  }
  match lookupSym(c, s) {
    case Some(_) -> {
    }
    case None -> report(
      c,
      id,
      "symbol-defined",
      what + " names symbol #" + toString(s.id) + " that no loaded package defines"
    )
  }
}

func substTy(t: in Ty, subs: in List[Subst], selfTy: in Option[Ty]): Ty {
  match t {
    case TPrim(_) -> t
    case TTuple(xs) -> TTuple(elems = substList(xs, subs, selfTy))
    case TNullable(i) -> TNullable(inner = substTy(i, subs, selfTy))
    case TFunc(ps, r, asy) -> {
      val res: List[TParamTy] = newList()
      for p in ps {
        res.add(TParamTy(mode = p.mode, ty = substTy(p.ty, subs, selfTy)))
      }
      TFunc(params = res, ret = substTy(r, subs, selfTy), isAsync = asy)
    }
    case TArray(len, e) -> TArray(len = substLen(len, subs), element = substTy(e, subs, selfTy))
    case TSlice(e) -> TSlice(element = substTy(e, subs, selfTy))
    case TNamed(s, args) -> TNamed(sym = s, args = substList(args, subs, selfTy))
    case TParam(o, i) -> {
      if i == selfParamIndex() {
        match selfTy {
          case Some(st) -> return st
          case None -> return t
        }
      }
      for s in subs {
        if symbolIdEq(s.owner, o) and i >= 0 and i < s.args.count {
          return s.args[i]
        }
      }
      t
    }
    case TRefined(u, lo, hi, inc) -> TRefined(
      underlying = substTy(u, subs, selfTy),
      lo = lo,
      hi = hi,
      hiInclusive = inc
    )
    case TLen(_) -> t
    case TNever -> t
    case TException -> t
    case TExtern(h) -> TExtern(host = HostTypeRef(name = h.name, args = substList(h.args, subs, selfTy)))
  }
}

func substLen(len: in ArrayLen, subs: in List[Subst]): ArrayLen {
  match len {
    case ALParam(o, i) -> {
      for s in subs {
        if symbolIdEq(s.owner, o) and i >= 0 and i < s.args.count {
          match s.args[i] {
            case TLen(n) -> return ALKnown(n = n)
            // A length that is itself a value parameter of the enclosing declaration.
            case TParam(o2, i2) -> return ALParam(owner = o2, index = i2)
            case _ -> {
            }
          }
        }
      }
      len
    }
    case _ -> len
  }
}

func substList(xs: in List[Ty], subs: in List[Subst], selfTy: in Option[Ty]): List[Ty] {
  val res: List[Ty] = newList()
  for x in xs {
    res.add(substTy(x, subs, selfTy))
  }
  res
}

func paramInScope(c: in Ctx, owner: in SymbolId, index: in Int): Bool {
  if symbolIdEq(owner, c.fnSym) {
    return index >= 0 and index < c.tpCount
  }
  if index == selfParamIndex() {
    match lookupSym(c, owner) {
      case Some(e) -> match e.kind { case TSkType -> return true; case _ -> return false }
      case None -> return false
    }
  }
  false
}

/// A type is closed when every parameter in it belongs to the declaration
/// being verified (or is the `Self` of an interface) and every symbol exists.
func checkTy(c: in Ctx, id: in NodeId, t: in Ty, what: in String): Unit {
  match t {
    case TPrim(_) -> {
    }
    case TTuple(xs) -> {
      for x in xs {
        checkTy(c, id, x, what)
      }
    }
    case TNullable(i) -> checkTy(c, id, i, what)
    case TFunc(ps, r, _) -> {
      for p in ps {
        checkTy(c, id, p.ty, what)
      }
      checkTy(c, id, r, what)
    }
    case TArray(len, e) -> {
      match len {
        case ALParam(o, i) -> if not paramInScope(c, o, i) {
          report(
            c,
            id,
            "closed-type",
            what + ": array length parameter " + toString(i) + " of #" + toString(o.id) + " is not in scope"
          )
        }
        case _ -> {
        }
      }
      checkTy(c, id, e, what)
    }
    case TSlice(e) -> checkTy(c, id, e, what)
    case TNamed(s, args) -> {
      requireSym(c, id, s, what)
      for a in args {
        checkTy(c, id, a, what)
      }
    }
    case TParam(o, i) -> if not paramInScope(c, o, i) {
      report(c, id, "closed-type", what + ": parameter " + toString(i) + " of #" + toString(o.id) + " is not in scope")
    }
    case TRefined(u, _, _, _) -> checkTy(c, id, u, what)
    case TLen(_) -> {
    }
    case TNever -> {
    }
    case TException -> {
    }
    case TExtern(h) -> {
      // The host name is not checked here: whether the host type exists is
      // the host-metadata reader's call at check time (docs/70 5.3), and TIR
      // is built only after that check.
      for a in h.args {
        checkTy(c, id, a, what)
      }
    }
  }
}

func expectTy(c: in Ctx, id: in NodeId, actual: in Ty, expected: in Ty, rule: in String, what: in String): Unit {
  if not tyEq(actual, expected) {
    report(c, id, rule, what + ": expected " + renderTy(expected) + " but found " + renderTy(actual))
  }
}

func isNever(t: in Ty): Bool {
  match t {
    case TNever -> true
    case _ -> false
  }
}

func defineLocal(c: in Ctx, id: in NodeId, d: in LocalDecl): Unit {
  if isTrue(c.allLocals, d.id.id) {
    report(c, id, "local-defined-once", "local #" + toString(d.id.id) + " (" + d.name + ") is bound more than once")
  }
  c.allLocals.add(d.id.id, true)
  c.locals.add(d.id.id, d)
  c.live.add(d.id.id, true)
  c.scopeIds.add(d.id.id)
  checkTy(c, id, d.ty, "local " + d.name)
}

/// A field reference names a field its owner declares, at that position.
func checkFieldRef(c: in Ctx, id: in NodeId, f: in FieldRef): Unit {
  match lookupSym(c, f.owner) {
    case Some(entry) -> if f.index < 0 or f.index >= entry.fields.count {
      report(
        c,
        id,
        "field-exists",
        "field " + f.name + " is not field " + toString(f.index) + " of #" + toString(f.owner.id)
      )
    } else if entry.fields[f.index].name != f.name {
      report(
        c,
        id,
        "field-exists",
        "field " + f.name + " is named " + entry.fields[f.index].name + " at position " + toString(f.index) + " of #" +
          toString(f.owner.id)
      )
    }
    case None -> if not isBuiltinSymbol(f.owner) {
      report(c, id, "symbol-defined", "field owner #" + toString(f.owner.id) + " is not defined by any loaded package")
    }
  }
}

func enterScope(c: in Ctx): Int {
  c.scopeIds.count
}

/// Closes the scope opened at `mark`: every local bound since is no longer
/// usable.  `locals` keeps the declaration (an id is bound once per package).
func exitScope(c: in Ctx, mark: in Int): Unit {
  while c.scopeIds.count > mark {
    val last = c.scopeIds.count - 1
    c.live.add(c.scopeIds[last], false)
    c.scopeIds.removeAt(last)
  }
}

func noteNode(c: in Ctx, id: in NodeId): Unit {
  if isTrue(c.seenNodes, id.id) {
    report(c, id, "node-unique", "NodeId #" + toString(id.id) + " is used by more than one node")
  }
  c.seenNodes.add(id.id, true)
}

func useLocal(c: in Ctx, id: in NodeId, l: in LocalId): Option[LocalDecl] {
  for f in c.frames {
    if isTrue(f.outer, l.id) and not isTrue(f.captured, l.id) {
      report(c, id, "local-captured", "local #" + toString(l.id) + " is used inside a closure that does not capture it")
    }
  }
  match mapGet(c.locals, l.id) {
    case Some(d) -> if isTrue(c.live, l.id) {
      Some(d)
    } else {
      report(c, id, "local-in-scope", "local " + d.name + " is used outside the scope that binds it")
      None
    }
    case None -> {
      report(c, id, "local-defined", "local #" + toString(l.id) + " is used before it is defined")
      None
    }
  }
}

func argTy(a: in TArg): Ty {
  match a {
    case TArgIn(v) -> v.ty
    case TArgOut(p) -> p.ty
    case TArgInout(p) -> p.ty
  }
}

func argMode(a: in TArg): TMode {
  match a {
    case TArgIn(_) -> TMIn
    case TArgOut(_) -> TMOut
    case TArgInout(_) -> TMInout
  }
}

func checkArgs(
  c: in Ctx,
  id: in NodeId,
  params: in List[TParamTy],
  args: in List[TArg],
  subs: in List[Subst],
  selfTy: in Option[Ty],
  callTy: in Ty,
  ret: in Ty,
): Unit {
  if params.count != args.count {
    report(
      c,
      id,
      "call-arity",
      "callee takes " + toString(params.count) + " argument(s) but the call passes " + toString(args.count)
    )
    return
  }
  var i = 0
  while i < params.count {
    val p = params[i]
    if not modeEq(p.mode, argMode(args[i])) {
      report(
        c,
        id,
        "call-arg-mode",
        "argument " + toString(i) + " is passed " + modeName(argMode(args[i])) + " but the parameter is " + modeName(p.mode)
      )
    }
    expectTy(c, id, argTy(args[i]), substTy(p.ty, subs, selfTy), "call-arg-type", "argument " + toString(i))
    i = i + 1
  }
  expectTy(c, id, callTy, substTy(ret, subs, selfTy), "call-result-type", "result")
}

func checkCallee(c: in Ctx, e: in TExpr, callee: in Callee, args: in List[TArg]): Unit {
  match callee {
    case Direct(sym, targs) -> {
      for t in targs {
        checkTy(c, e.id, t, "type argument")
      }
      match lookupSym(c, sym) {
        case Some(entry) -> match entry.sig {
          case Some(sg) -> {
            if targs.count != sg.typeParamCount {
              report(
                c,
                e.id,
                "call-type-args",
                "callee has " + toString(sg.typeParamCount) + " type parameter(s) but the call gives " + toString(targs.count)
              )
              return
            }
            val subs: List[Subst] = newList()
            subs.add(Subst(owner = sym, args = targs))
            checkArgs(c, e.id, sg.params, args, subs, None, e.ty, sg.ret)
          }
          case None -> report(
            c,
            e.id,
            "callee-callable",
            "symbol #" + toString(sym.id) + " has no signature to call"
          )
        }
        case None -> if not isBuiltinSymbol(sym) {
          report(c, e.id, "symbol-defined", "callee symbol #" + toString(sym.id) + " is not defined by any loaded package")
        }
      }
    }
    case Interface(iface, iargs, method, targs) -> {
      for t in targs {
        checkTy(c, e.id, t, "type argument")
      }
      for t in iargs {
        checkTy(c, e.id, t, "interface argument")
      }
      requireSym(c, e.id, iface, "interface callee")
      match lookupSym(c, method) {
        case Some(entry) -> match entry.sig {
          case Some(sg) -> {
            if targs.count != sg.typeParamCount {
              report(
                c,
                e.id,
                "call-type-args",
                "method has " + toString(sg.typeParamCount) + " type parameter(s) but the call gives " + toString(targs.count)
              )
              return
            }
            val subs: List[Subst] = newList()
            subs.add(Subst(owner = method, args = targs))
            subs.add(Subst(owner = iface, args = iargs))
            val selfTy: Option[Ty] = if args.count > 0 { Some(argTy(args[0])) } else { None }
            checkArgs(c, e.id, sg.params, args, subs, selfTy, e.ty, sg.ret)
          }
          case None -> report(
            c,
            e.id,
            "callee-callable",
            "method #" + toString(method.id) + " has no signature to call"
          )
        }
        case None -> report(
          c,
          e.id,
          "symbol-defined",
          "interface method #" + toString(method.id) + " is not defined by any loaded package"
        )
      }
    }
    case Indirect(fnValue) -> match fnValue.ty {
      case TFunc(ps, r, _) -> checkArgs(c, e.id, ps, args, newList(), None, e.ty, r)
      case _ -> report(
        c,
        e.id,
        "callee-callable",
        "an indirect call through a value of type " + renderTy(fnValue.ty) +
          ", which is not a function type"
      )
    }
    case Extern(member) -> checkArgs(c, e.id, member.params, args, newList(), None, e.ty, member.ret)
    case Intrinsic(_) -> {
    }
  }
}

func placeMutable(c: in Ctx, id: in NodeId, p: in TPlace): Unit {
  match p.kind {
    case PlLocal(l) -> match useLocal(c, id, l) {
      case Some(d) -> {
        if not d.mutable {
          report(c, id, "assign-mutable", "assignment to the immutable local " + d.name)
        }
        expectTy(c, id, p.ty, d.ty, "place-type", "local place")
      }
      case None -> {
      }
    }
    case PlGlobal(s) -> match lookupSym(c, s) {
      case Some(entry) -> if not entry.mutable {
        report(c, id, "assign-mutable", "assignment to the immutable global #" + toString(s.id))
      }
      case None -> report(
        c,
        id,
        "symbol-defined",
        "global place names symbol #" + toString(s.id) +
          " that no loaded package defines"
      )
    }
    case PlField(recv, f) -> {
      visitExpr(c, recv)
      match lookupSym(c, f.owner) {
        case Some(entry) -> if f.index < 0 or f.index >= entry.fields.count {
          report(
            c,
            id,
            "field-exists",
            "field " + f.name + " is not field " + toString(f.index) + " of #" + toString(f.owner.id)
          )
        } else if not entry.fields[f.index].mutable {
          report(c, id, "assign-mutable", "assignment to the immutable field " + f.name)
        }
        case None -> report(
          c,
          id,
          "symbol-defined",
          "field owner #" + toString(f.owner.id) + " is not defined by any loaded package"
        )
      }
    }
    case PlIndex(recv, idx, _) -> {
      visitExpr(c, recv)
      visitExpr(c, idx)
    }
  }
  checkTy(c, id, p.ty, "place")
}

func visitPlaceValue(c: in Ctx, id: in NodeId, p: in TPlace): Unit {
  match p.kind {
    case PlLocal(l) -> {
      match useLocal(c, id, l) {
        case Some(d) -> expectTy(c, id, p.ty, d.ty, "place-type", "local place")
        case None -> {
        }
      }
    }
    case PlGlobal(s) -> requireSym(c, id, s, "global place")
    case PlField(recv, _) -> visitExpr(c, recv)
    case PlIndex(recv, idx, _) -> {
      visitExpr(c, recv)
      visitExpr(c, idx)
    }
  }
  checkTy(c, id, p.ty, "place")
}

func visitPat(c: in Ctx, p: in TPat, defs: in Bool): Unit {
  noteNode(c, p.id)
  checkTy(c, p.id, p.ty, "pattern")
  match p.kind {
    case TpWild -> {
    }
    case TpBind(d, inner) -> {
      if defs {
        defineLocal(c, p.id, d)
      }
      expectTy(c, p.id, d.ty, p.ty, "pattern-binding-type", "binding " + d.name)
      match inner {
        case Some(ip) -> visitPat(c, ip, defs)
        case None -> {
        }
      }
    }
    case TpLit(_) -> {
    }
    case TpRange(_, _, _) -> {
    }
    case TpCtor(sym, args) -> {
      requireSym(c, p.id, sym, "constructor pattern")
      match lookupSym(c, sym) {
        case Some(entry) -> match entry.sig {
          case Some(sg) -> if sg.params.count != args.count {
            report(
              c,
              p.id,
              "pattern-arity",
              "case #" + toString(sym.id) + " has " + toString(sg.params.count) + " field(s) but the pattern has " +
                toString(args.count)
            )
          }
          case None -> report(
            c,
            p.id,
            "pattern-callable",
            "case #" + toString(sym.id) + " has no signature to match against"
          )
        }
        case None -> {
        }
      }
      for a in args {
        visitPat(c, a, defs)
      }
    }
    case TpRecord(sym, fields) -> {
      requireSym(c, p.id, sym, "record pattern")
      for f in fields {
        checkFieldRef(c, p.id, f.field)
        visitPat(c, f.pat, defs)
      }
    }
    case TpTuple(elems) -> {
      for x in elems {
        visitPat(c, x, defs)
      }
    }
    case TpTypeTest(inner, ty) -> {
      checkTy(c, p.id, ty, "type test")
      visitPat(c, inner, defs)
    }
    case TpOr(alts) -> {
      var first = true
      for a in alts {
        visitPat(c, a, defs and first)
        first = false
      }
    }
    case TpConst(sym) -> requireSym(c, p.id, sym, "constant pattern")
  }
}

func visitStmt(c: in Ctx, s: in TStmt): Unit {
  noteNode(c, s.id)
  match s.kind {
    case TsLet(pat, init) -> {
      visitExpr(c, init)
      visitPat(c, pat, true)
      expectTy(c, s.id, pat.ty, init.ty, "let-type", "binding pattern")
    }
    case TsVar(d, init) -> {
      match init {
        case Some(e) -> {
          visitExpr(c, e)
          expectTy(c, s.id, e.ty, d.ty, "let-type", "initialiser of " + d.name)
        }
        case None -> {
        }
      }
      defineLocal(c, s.id, d)
    }
    case TsExpr(e) -> visitExpr(c, e)
    case TsReturn(v) -> match v { case Some(e) -> visitExpr(c, e); case None -> {  } }
    case TsBreak(_) -> {
    }
    case TsContinue(_) -> {
    }
    case TsThrow(e) -> visitExpr(c, e)
    case TsTry(body, catches, fin) -> {
      visitExpr(c, body)
      for k in catches {
        val mark = enterScope(c)
        match k.binding {
          case Some(d) -> defineLocal(c, s.id, d)
          case None -> {
          }
        }
        visitExpr(c, k.body)
        exitScope(c, mark)
      }
      match fin {
        case Some(f) -> visitExpr(c, f)
        case None -> {
        }
      }
    }
    case TsDefer(b) -> visitExpr(c, b)
    case TsScope(binding, body) -> {
      val mark = enterScope(c)
      match binding {
        case Some(d) -> defineLocal(c, s.id, d)
        case None -> {
        }
      }
      visitExpr(c, body)
      exitScope(c, mark)
    }
    case TsFor(_, pat, iter, body) -> {
      visitExpr(c, iter)
      val mark = enterScope(c)
      visitPat(c, pat, true)
      visitExpr(c, body)
      exitScope(c, mark)
    }
    case TsWhile(_, cond, body) -> {
      visitExpr(c, cond)
      expectTy(c, s.id, cond.ty, tyBool(), "condition-type", "while condition")
      visitExpr(c, body)
    }
    case TsLoop(_, body) -> visitExpr(c, body)
    case TsInvariant(e) -> {
      visitExpr(c, e)
      expectTy(c, s.id, e.ty, tyBool(), "condition-type", "invariant")
    }
  }
}

func branchTy(c: in Ctx, id: in NodeId, branch: in TExpr, nodeTy: in Ty, what: in String): Unit {
  if not isNever(branch.ty) {
    expectTy(c, id, branch.ty, nodeTy, "branch-type", what)
  }
}

func visitExpr(c: in Ctx, e: in TExpr): Unit {
  noteNode(c, e.id)
  checkTy(c, e.id, e.ty, "expression")
  match e.kind {
    case XLit(_) -> {
    }
    case XLocal(l) -> match useLocal(c, e.id, l) {
      case Some(d) -> expectTy(c, e.id, e.ty, d.ty, "local-type", "local " + d.name)
      case None -> {
      }
    }
    case XGlobal(sym, targs) -> {
      requireSym(c, e.id, sym, "global")
      for t in targs {
        checkTy(c, e.id, t, "type argument")
      }
    }
    case XCall(callee, args) -> {
      match callee {
        case Indirect(fv) -> visitExpr(c, fv)
        case _ -> {
        }
      }
      for a in args {
        match a {
          case TArgIn(v) -> visitExpr(c, v)
          case TArgOut(p) -> visitPlaceValue(c, e.id, p)
          case TArgInout(p) -> visitPlaceValue(c, e.id, p)
        }
      }
      checkCallee(c, e, callee, args)
    }
    case XConstruct(sym, fields) -> {
      requireSym(c, e.id, sym, "construction")
      for f in fields {
        visitExpr(c, f)
      }
      checkConstruct(c, e, sym, fields)
    }
    case XField(recv, f) -> {
      visitExpr(c, recv)
      match lookupSym(c, f.owner) {
        case Some(entry) -> if f.index < 0 or f.index >= entry.fields.count {
          report(
            c,
            e.id,
            "field-exists",
            "field " + f.name + " is not field " + toString(f.index) + " of #" + toString(f.owner.id)
          )
        }
        case None -> if not isBuiltinSymbol(f.owner) {
          report(c, e.id, "symbol-defined", "field owner #" + toString(f.owner.id) + " is not defined by any loaded package")
        }
      }
    }
    case XCopy(base, updates) -> {
      visitExpr(c, base)
      expectTy(c, e.id, e.ty, base.ty, "copy-type", "record copy")
      for u in updates {
        visitExpr(c, u.value)
      }
      checkCopy(c, e, base, updates)
    }
    case XIndex(recv, idx, _) -> {
      visitExpr(c, recv)
      visitExpr(c, idx)
    }
    case XConvert(kind, inner) -> {
      visitExpr(c, inner)
      match kind {
        case CvWiden(to) -> expectTy(c, e.id, e.ty, TPrim(to), "convert-type", "widening result")
        case CvLiftNullable -> expectTy(c, e.id, e.ty, TNullable(inner = inner.ty), "convert-type", "nullable lift")
        case CvFromHost -> match inner.ty {
          case TExtern(_) -> ()
          case _ -> report(
            c,
            e.id,
            "convert-type",
            "CvFromHost applied to a value of type " + renderTy(inner.ty) +
              ", which is not a host type"
          )
        }
        case CvFromNever -> if not isNever(inner.ty) {
          report(c, e.id, "convert-type", "CvFromNever applied to a value of type " + renderTy(inner.ty))
        }
        case _ -> {
        }
      }
    }
    case XTuple(elems) -> {
      for x in elems {
        visitExpr(c, x)
      }
    }
    case XTupleField(recv, index) -> {
      visitExpr(c, recv)
      match recv.ty {
        case TTuple(elems) -> if index < 0 or index >= elems.count {
          report(c, e.id, "tuple-field", "element " + toString(index) + " of a tuple of " + toString(elems.count))
        } else {
          expectTy(c, e.id, e.ty, elems[index], "tuple-field-type", "tuple element " + toString(index))
        }
        case _ -> report(c, e.id, "tuple-field", "tuple element access on a value of type " + renderTy(recv.ty))
      }
    }
    case XListLit(elems) -> {
      for x in elems {
        visitExpr(c, x)
      }
    }
    case XInterp(parts) -> {
      for x in parts {
        visitExpr(c, x)
        expectTy(c, e.id, x.ty, tyString(), "interp-part-type", "interpolation part")
      }
    }
    case XRange(lo, hi, _) -> {
      visitExpr(c, lo)
      visitExpr(c, hi)
      expectTy(c, e.id, hi.ty, lo.ty, "range-type", "range bounds")
    }
    case XShort(op, l, r) -> {
      visitExpr(c, l)
      visitExpr(c, r)
      match op {
        case ShCoalesce -> {
        }
        case _ -> {
          expectTy(c, e.id, l.ty, tyBool(), "condition-type", "left operand")
          expectTy(c, e.id, r.ty, tyBool(), "condition-type", "right operand")
          expectTy(c, e.id, e.ty, tyBool(), "short-circuit-type", "result")
        }
      }
    }
    case XIf(cond, t, el) -> {
      visitExpr(c, cond)
      expectTy(c, e.id, cond.ty, tyBool(), "condition-type", "if condition")
      visitExpr(c, t)
      match el {
        case Some(x) -> {
          visitExpr(c, x)
          branchTy(c, e.id, t, e.ty, "then branch")
          branchTy(c, e.id, x, e.ty, "else branch")
        }
        case None -> expectTy(c, e.id, e.ty, tyUnit(), "branch-type", "if without else")
      }
    }
    case XMatch(scrut, arms, _) -> {
      visitExpr(c, scrut)
      for a in arms {
        val mark = enterScope(c)
        visitPat(c, a.pat, true)
        expectTy(c, e.id, a.pat.ty, scrut.ty, "pattern-type", "arm pattern")
        match a.guard {
          case Some(g) -> {
            visitExpr(c, g)
            expectTy(c, e.id, g.ty, tyBool(), "condition-type", "arm guard")
          }
          case None -> {
          }
        }
        visitExpr(c, a.body)
        branchTy(c, e.id, a.body, e.ty, "match arm")
        exitScope(c, mark)
      }
    }
    case XBlock(stmts, tail) -> {
      val mark = enterScope(c)
      for s in stmts {
        visitStmt(c, s)
      }
      match tail {
        case Some(t) -> {
          visitExpr(c, t)
          branchTy(c, e.id, t, e.ty, "block tail")
        }
        case None -> {
        }
      }
      exitScope(c, mark)
    }
    case XUnsafe(b) -> {
      visitExpr(c, b)
      branchTy(c, e.id, b, e.ty, "unsafe body")
    }
    case XLambda(params, caps, body) -> visitLambda(c, e, params, caps, body)
    case XAwait(i) -> visitExpr(c, i)
    case XSpawn(i) -> visitExpr(c, i)
    case XYield(i) -> visitExpr(c, i)
    case XPropagate(i) -> visitExpr(c, i)
    case XOld(i) -> {
      visitExpr(c, i)
      expectTy(c, e.id, e.ty, i.ty, "old-type", "old")
    }
    case XResult -> {
    }
    case XForall(bs, w, body) -> visitQuant(c, e, bs, w, body)
    case XExists(bs, w, body) -> visitQuant(c, e, bs, w, body)
    case XAssign(place, _, value) -> {
      visitExpr(c, value)
      placeMutable(c, e.id, place)
      expectTy(c, e.id, value.ty, place.ty, "assign-type", "assigned value")
      expectTy(c, e.id, e.ty, tyUnit(), "assign-type", "assignment result")
    }
  }
}

func visitQuant(c: in Ctx, e: in TExpr, bs: in List[LocalDecl], w: in Option[TExpr], body: in TExpr): Unit {
  val mark = enterScope(c)
  for b in bs {
    defineLocal(c, e.id, b)
  }
  match w {
    case Some(x) -> {
      visitExpr(c, x)
      expectTy(c, e.id, x.ty, tyBool(), "condition-type", "where clause")
    }
    case None -> {
    }
  }
  visitExpr(c, body)
  expectTy(c, e.id, body.ty, tyBool(), "condition-type", "quantifier body")
  expectTy(c, e.id, e.ty, tyBool(), "condition-type", "quantifier")
  exitScope(c, mark)
}

func visitLambda(c: in Ctx, e: in TExpr, params: in List[LocalDecl], caps: in List[Capture], body: in TExpr): Unit {
  val outer: Map[Int, Bool] = newMap()
  val captured: Map[Int, Bool] = newMap()
  for k in mapKeys(c.live) {
    if isTrue(c.live, k) {
      outer.add(k, true)
    }
  }
  for cp in caps {
    captured.add(cp.local.id, true)
    if not isTrue(outer, cp.local.id) {
      report(
        c,
        e.id,
        "local-defined",
        "closure captures local #" + toString(cp.local.id) + ", which is not defined where the closure is created"
      )
    }
  }
  val mark = enterScope(c)
  for p in params {
    defineLocal(c, e.id, p)
  }
  c.frames.add(LambdaFrame(outer = outer, captured = captured))
  visitExpr(c, body)
  c.frames.removeAt(c.frames.count - 1)
  exitScope(c, mark)
  match e.ty {
    case TFunc(ps, r, _) -> {
      if ps.count != params.count {
        report(
          c,
          e.id,
          "lambda-type",
          "closure type has " + toString(ps.count) + " parameter(s) but the closure declares " + toString(params.count)
        )
      }
      branchTy(c, e.id, body, r, "closure body")
    }
    case _ -> report(c, e.id, "lambda-type", "closure has type " + renderTy(e.ty) + ", which is not a function type")
  }
}

func checkCopy(c: in Ctx, e: in TExpr, base: in TExpr, updates: in List[TFieldUpdate]): Unit {
  val owner = match base.ty {
    case TNamed(o, _) -> o
    case _ -> {
      report(
        c,
        e.id,
        "copy-type",
        "a record copy of a value of type " + renderTy(base.ty) + ", which is not a declared type"
      )
      return
    }
  }
  val entry = match lookupSym(c, owner) { case Some(en) -> en; case None -> return }
  val subs: List[Subst] = newList()
  match base.ty {
    case TNamed(o, args) -> subs.add(Subst(owner = o, args = args))
    case _ -> ()
  }
  for u in updates {
    if u.field.index < 0 or u.field.index >= entry.fields.count or entry.fields[u.field.index].name != u.field.name {
      report(
        c,
        e.id,
        "field-exists",
        "copy updates field " + u.field.name + ", which is not field " + toString(u.field.index) + " of #" +
          toString(owner.id)
      )
    } else {
      expectTy(
        c,
        e.id,
        u.value.ty,
        substTy(entry.fields[u.field.index].ty, subs, None),
        "copy-field-type",
        "field " + u.field.name
      )
    }
  }
}

func checkConstruct(c: in Ctx, e: in TExpr, sym: in SymbolId, fields: in List[TExpr]): Unit {
  match lookupSym(c, sym) {
    case Some(entry) -> {
      if fields.count != entry.fields.count {
        report(
          c,
          e.id,
          "construct-arity",
          "#" + toString(sym.id) + " has " + toString(entry.fields.count) + " field(s) but the construction gives " +
            toString(fields.count)
        )
        return
      }
      val subs: List[Subst] = newList()
      match e.ty {
        case TNamed(owner, args) -> {
          subs.add(Subst(owner = owner, args = args))
          subs.add(Subst(owner = sym, args = args))
        }
        case _ -> report(
          c,
          e.id,
          "construct-type",
          "construction has type " + renderTy(e.ty) + ", which is not a declared type"
        )
      }
      var i = 0
      while i < fields.count {
        expectTy(
          c,
          e.id,
          fields[i].ty,
          substTy(entry.fields[i].ty, subs, None),
          "construct-field-type",
          "field " + entry.fields[i].name
        )
        i = i + 1
      }
    }
    case None -> {
    }
  }
}

func verifyFn(shared: in Ctx, f: in TFnDecl): Unit {
  val c = Ctx(
    diags = shared.diags,
    seenNodes = shared.seenNodes,
    allLocals = newMap(),
    syms = shared.syms,
    fnSym = f.sym,
    tpCount = f.typeParams.count,
    locals = newMap(),
    live = newMap(),
    scopeIds = newList(),
    frames = newList()
  )
  val none = NodeId(id = 0)
  for p in f.params {
    defineLocal(c, none, p.local)
    match p.dflt {
      case Some(d) -> visitExpr(c, d)
      case None -> {
      }
    }
  }
  checkTy(c, none, f.ret, "return type")
  for r in f.preconds {
    visitExpr(c, r)
    expectTy(c, r.id, r.ty, tyBool(), "condition-type", "precondition")
  }
  for r in f.postconds {
    visitExpr(c, r)
    expectTy(c, r.id, r.ty, tyBool(), "condition-type", "postcondition")
  }
  match f.barrier {
    case Some(g) -> {
      visitExpr(c, g)
      expectTy(c, g.id, g.ty, tyBool(), "condition-type", "entry barrier")
    }
    case None -> {
    }
  }
  match f.body {
    case Some(b) -> {
      visitExpr(c, b)
      branchTy(c, b.id, b, f.ret, "function body")
    }
    case None -> {
    }
  }
}

/// Every broken rule in `pkg`, with the declarations of `deps` (loaded
/// interfaces) visible to it.  Empty means the package is well formed.
pub func verifyPackage(pkg: in TPackage, deps: in List[TSymEntry]): List[VerifyDiag] {
  val syms: Map[Int, TSymEntry] = newMap()
  for d in deps {
    syms.add(d.sym.id, d)
  }
  for s in pkg.symbols {
    syms.add(s.sym.id, s)
  }
  val shared = Ctx(
    diags = newList(),
    seenNodes = newMap(),
    allLocals = newMap(),
    syms = syms,
    fnSym = SymbolId(id = 0),
    tpCount = 0,
    locals = newMap(),
    live = newMap(),
    scopeIds = newList(),
    frames = newList()
  )
  for f in pkg.funcs {
    requireSym(shared, NodeId(id = 0), f.sym, "function " + toString(f.sym.id))
    verifyFn(shared, f)
  }
  shared.diags
}
