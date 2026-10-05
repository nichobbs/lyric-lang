//! value_record_methods.l — the methods of a value-generic record become
//! value-generic functions named after it (D173 item 2).
//!
//! `record Ints[N: Nat] { var data: array[N, Int]; func sum(self: in Ints[N]): Int {...} }`
//! becomes the record without its methods plus
//! `func Ints.sum[N: Nat](self: in Ints[N]): Int {...}`, which `Lyric.Mono`
//! specialises per length at each call, in whichever package makes the call
//! (#8173).  Runs on the parsed file, before anything reads its items, so the
//! checker, contract metadata, in-bundle consumers and every backend see the
//! functions.  A method body may read and write the record's fields by bare
//! name; each such use not shadowed by a parameter or local becomes
//! `self.<field>`, as a free function has no implicit receiver.
package Lyric.Pipeline

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

pub func hoistValueRecordMethods(file: in SourceFile): SourceFile {
  var changed = false
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IRecord(d) -> if recordHasValueGenerics(d) and recordHasMethods(d) {
        changed = true
        items.add(it.copy(kind = IRecord(decl = recordWithoutMethods(d))))
        addHoistedMethods(d, it.visibility, items)
      } else {
        items.add(it)
      }
      case IExposedRec(d) -> if recordHasValueGenerics(d) and recordHasMethods(d) {
        changed = true
        items.add(it.copy(kind = IExposedRec(decl = recordWithoutMethods(d))))
        addHoistedMethods(d, it.visibility, items)
      } else {
        items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  if changed {
    file.copy(items = items)
  } else {
    file
  }
}

func recordHasValueGenerics(d: in RecordDecl): Bool {
  match d.generics {
    case Some(gp) -> {
      for p in gp.params {
        match p {
          case GPValue(_, _, _) -> return true
          case GPType(_, _) -> ()
        }
      }
      false
    }
    case None -> false
  }
}

func recordHasMethods(d: in RecordDecl): Bool {
  for m in d.members {
    match m {
      case RMFunc(_) -> return true
      case _ -> ()
    }
  }
  false
}

func recordWithoutMethods(d: in RecordDecl): RecordDecl {
  val members: List[RecordMember] = newList()
  for m in d.members {
    match m {
      case RMFunc(_) -> ()
      case _ -> members.add(m)
    }
  }
  d.copy(members = members)
}

/// The names a method body may use without `self.`: each field (`true`) and
/// each method (`false`), which a bare call `m(...)` reaches on `self`.
func recordMemberNames(d: in RecordDecl): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  for m in d.members {
    match m {
      case RMField(f) -> if not names.containsKey(f.name) { names.add(f.name, true) }
      case RMFunc(fn) -> if not names.containsKey(fn.name) { names.add(fn.name, false) }
      case _ -> ()
    }
  }
  names
}

/// A method with no visibility of its own is reachable wherever its record
/// is, so its function takes the record's.
func addHoistedMethods(d: in RecordDecl, recordVis: in Option[Visibility], acc: in List[Item]): Unit {
  val fields = recordMemberNames(d)
  for m in d.members {
    match m {
      case RMFunc(fn0) -> {
        val fn = match fn0.visibility { case Some(_) -> fn0; case None -> fn0.copy(visibility = recordVis) }
        val hoisted = hoistMethod(d, fields, fn)
        acc.add(
          Item(
            docComments = hoisted.docComments,
            annotations = hoisted.annotations,
            visibility = hoisted.visibility,
            kind = IFunc(decl = hoisted),
            span = hoisted.span
          )
        )
      }
      case _ -> ()
    }
  }
}

/// The record's instance type over its own parameters, `Ints[N]`.
func recordInstanceType(d: in RecordDecl, sp: in Span): TypeExpr {
  val args: List[TypeArg] = newList()
  match d.generics {
    case Some(gp) -> {
      for p in gp.params {
        args.add(TAType(ty = TypeExpr(kind = TRef(path = oneSegmentPath(genericParamName(p), sp)), span = sp)))
      }
    }
    case None -> ()
  }
  TypeExpr(kind = TGenericApp(head = oneSegmentPath(d.name, sp), args = args), span = sp)
}

func oneSegmentPath(name: in String, sp: in Span): ModulePath {
  val segs: List[String] = newList()
  segs.add(name)
  ModulePath(segments = segs, span = sp)
}

func genericParamName(p: in GenericParam): String {
  match p {
    case GPType(n, _) -> n
    case GPValue(n, _, _) -> n
  }
}

func hoistMethod(d: in RecordDecl, fields: in Map[String, Bool], fn: in FunctionDecl): FunctionDecl {
  val selfTy = recordInstanceType(d, fn.span)
  val params: List[Param] = newList()
  val bound: List[String] = newList()
  for p in fn.params {
    params.add(p.copy(ty = withoutSelfType(p.ty, selfTy)))
    bound.add(p.name)
  }
  val contracts: List[ContractClause] = newList()
  for c in fn.contracts {
    contracts.add(sfContract(c, fields, bound, selfTy))
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = d.name + "." + fn.name,
    generics = Some(value = mergedGenerics(d.generics, fn.generics, fn.span)),
    params = params,
    ret = match fn.ret { case Some(r) -> Some(value = withoutSelfType(r, selfTy)); case None -> None },
    whereClause = mergedWhere(d.whereClause, fn.whereClause),
    contracts = contracts,
    body = match fn.body { case Some(b) -> Some(value = sfFunctionBody(b, fields, bound, selfTy)); case None -> None },
    span = fn.span
  )
}

func mergedGenerics(owner: in Option[GenericParams], own: in Option[GenericParams], sp: in Span): GenericParams {
  val ps: List[GenericParam] = newList()
  match owner {
    case Some(g) -> {
      for p in g.params {
        ps.add(p)
      }
    }
    case None -> ()
  }
  match own {
    case Some(g) -> {
      for p in g.params {
        ps.add(p)
      }
    }
    case None -> ()
  }
  val gsp = match owner { case Some(g) -> g.span; case None -> sp }
  GenericParams(params = ps, span = gsp, legacyPrefixForm = false)
}

func mergedWhere(owner: in Option[WhereClause], own: in Option[WhereClause]): Option[WhereClause] {
  match owner {
    case None -> own
    case Some(ow) -> match own {
      case None -> owner
      case Some(fw) -> {
        val bounds: List[WhereBound] = newList()
        for b in ow.bounds {
          bounds.add(b)
        }
        for b in fw.bounds {
          bounds.add(b)
        }
        Some(value = WhereClause(bounds = bounds, span = ow.span))
      }
    }
  }
}

/// `Self` names the record's instance type in a method; a free function
/// spells it out.
func withoutSelfType(t: in TypeExpr, selfTy: in TypeExpr): TypeExpr {
  match t.kind {
    case TSelf -> selfTy.copy(span = t.span)
    case TGenericApp(head, args) -> {
      val acc: List[TypeArg] = newList()
      for a in args {
        acc.add(withoutSelfTypeArg(a, selfTy))
      }
      t.copy(kind = TGenericApp(head = head, args = acc))
    }
    case TArray(size, el) -> t.copy(kind = TArray(size = size, element = withoutSelfType(el, selfTy)))
    case TSlice(el) -> t.copy(kind = TSlice(element = withoutSelfType(el, selfTy)))
    case TTuple(ts) -> t.copy(kind = TTuple(types = withoutSelfTypes(ts, selfTy)))
    case TNullable(inner) -> t.copy(kind = TNullable(inner = withoutSelfType(inner, selfTy)))
    case TParen(inner) -> t.copy(kind = TParen(inner = withoutSelfType(inner, selfTy)))
    case TFunction(ps, r) -> t.copy(
      kind = TFunction(
        parameters = withoutSelfTypes(ps, selfTy),
        retTy = withoutSelfType(r, selfTy)
      )
    )
    case _ -> t
  }
}

func withoutSelfTypeArg(a: in TypeArg, selfTy: in TypeExpr): TypeArg {
  match a {
    case TAType(t) -> TAType(ty = withoutSelfType(t, selfTy))
    case TAValue(_) -> a
  }
}

func withoutSelfTypes(ts: in List[TypeExpr], selfTy: in TypeExpr): List[TypeExpr] {
  val acc: List[TypeExpr] = newList()
  for t in ts {
    acc.add(withoutSelfType(t, selfTy))
  }
  acc
}

func withoutSelfTypeOpt(t: in Option[TypeExpr], selfTy: in TypeExpr): Option[TypeExpr] {
  match t {
    case Some(te) -> Some(value = withoutSelfType(te, selfTy))
    case None -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bare field names to `self.<field>`.  `bound` holds the names a parameter or
// local in names binds, which shadow a field; each nested names works on its
// own copy.
// ─────────────────────────────────────────────────────────────────────────────
func extendedScope(bound: in List[String]): List[String] {
  val acc: List[String] = newList()
  for b in bound {
    acc.add(b)
  }
  acc
}

func isBoundName(bound: in List[String], name: in String): Bool {
  for b in bound {
    if b == name {
      return true
    }
  }
  false
}

func sfContract(
  c: in ContractClause, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr
): ContractClause {
  match c {
    case CCRequires(e, sp) -> CCRequires(expr = sfExprT(e, fields, bound, selfTy), span = sp)
    case CCEnsures(e, sp) -> CCEnsures(expr = sfExprT(e, fields, bound, selfTy), span = sp)
    case CCWhen(e, sp) -> CCWhen(expr = sfExprT(e, fields, bound, selfTy), span = sp)
    case CCDecreases(e, sp) -> CCDecreases(expr = sfExprT(e, fields, bound, selfTy), span = sp)
    case _ -> c
  }
}

func sfFunctionBody(
  b: in FunctionBody, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr
): FunctionBody {
  match b {
    case FBExpr(e) -> FBExpr(expr = sfExprT(e, fields, bound, selfTy))
    case FBBlock(blk) -> FBBlock(block = sfBlock(blk, fields, bound, selfTy))
  }
}

func sfBlock(b: in Block, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): Block {
  val names = extendedScope(bound)
  val stmts: List[Statement] = newList()
  for s in b.statements {
    stmts.add(sfStmt(s, fields, names, selfTy))
  }
  b.copy(statements = stmts)
}

func sfEob(x: in ExprOrBlock, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): ExprOrBlock {
  match x {
    case EOBExpr(e) -> EOBExpr(expr = sfExprT(e, fields, bound, selfTy))
    case EOBBlock(b) -> EOBBlock(block = sfBlock(b, fields, bound, selfTy))
  }
}

func sfExprs(es: in List[Expr], fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): List[Expr] {
  val acc: List[Expr] = newList()
  for x in es {
    acc.add(sfExprT(x, fields, bound, selfTy))
  }
  acc
}

func sfExprOpt(
  e: in Option[Expr], fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr
): Option[Expr] {
  match e {
    case Some(x) -> Some(value = sfExprT(x, fields, bound, selfTy))
    case None -> None
  }
}

func sfPath(e: in Expr, p: in ModulePath, fields: in Map[String, Bool], bound: in List[String]): Expr {
  if p.segments.count == 1 and isMemberOfKind(fields, p.segments[0], true) and not isBoundName(bound, p.segments[0]) {
    onSelf(e, p.segments[0])
  } else {
    e
  }
}

func isMemberOfKind(members: in Map[String, Bool], name: in String, isField: in Bool): Bool {
  match mapGet(members, name) {
    case Some(f) -> f == isField
    case None -> false
  }
}

// The receiver takes an empty span at the name's start: sites are keyed by
// span, and the whole `self.x` keeps the name's, so the two never share one.
func onSelf(e: in Expr, member: in String): Expr {
  val selfSpan = e.span.copy(endPos = e.span.startPos)
  e.copy(kind = EMember(receiver = Expr(kind = ESelf, span = selfSpan), memberName = member))
}

/// A call's callee: a bare sibling method name is called on `self`.
func sfCallee(f: in Expr, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): Expr {
  match f.kind {
    case EPath(p) -> if p.segments.count == 1 and isMemberOfKind(fields, p.segments[0], false) and not isBoundName(bound, p.segments[0]) {
      onSelf(f, p.segments[0])
    } else {
      sfPath(f, p, fields, bound)
    }
    case _ -> sfExprT(f, fields, bound, selfTy)
  }
}

func sfExprT(e: in Expr, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): Expr {
  match e.kind {
    case EPath(p) -> sfPath(e, p, fields, bound)
    case EInterpolated(segs) -> {
      val acc: List[InterpolatedSegment] = newList()
      for s in segs {
        acc.add(sfSegment(s, fields, bound, selfTy))
      }
      e.copy(kind = EInterpolated(segments = acc))
    }
    case EParen(x) -> e.copy(kind = EParen(inner = sfExprT(x, fields, bound, selfTy)))
    case ETuple(xs) -> e.copy(kind = ETuple(exprs = sfExprs(xs, fields, bound, selfTy)))
    case EList(xs) -> e.copy(kind = EList(exprs = sfExprs(xs, fields, bound, selfTy)))
    case EIf(c, t, el, form) -> e.copy(
      kind = EIf(
        cond = sfExprT(c, fields, bound, selfTy),
        thenBranch = sfEob(t, fields, bound, selfTy),
        elseBranch = sfEobOpt(el, fields, bound, selfTy),
        thenForm = form
      )
    )
    case EMatch(scr, arms) -> {
      val acc: List[MatchArm] = newList()
      for a in arms {
        acc.add(sfArm(a, fields, bound, selfTy))
      }
      e.copy(kind = EMatch(scrutinee = sfExprT(scr, fields, bound, selfTy), arms = acc))
    }
    case EAwait(x) -> e.copy(kind = EAwait(inner = sfExprT(x, fields, bound, selfTy)))
    case EYield(x) -> e.copy(kind = EYield(inner = sfExprT(x, fields, bound, selfTy)))
    case ESpawn(x) -> e.copy(kind = ESpawn(inner = sfExprT(x, fields, bound, selfTy)))
    case ETry(x) -> e.copy(kind = ETry(inner = sfExprT(x, fields, bound, selfTy)))
    case EOld(x) -> e.copy(kind = EOld(inner = sfExprT(x, fields, bound, selfTy)))
    case EForall(bs, w, body) -> {
      val names = binderScope(bound, bs)
      e.copy(
        kind = EForall(
          binders = bs,
          whereExpr = sfExprOpt(w, fields, names, selfTy),
          body = sfExprT(body, fields, names, selfTy)
        )
      )
    }
    case EExists(bs, w, body) -> {
      val names = binderScope(bound, bs)
      e.copy(
        kind = EExists(
          binders = bs,
          whereExpr = sfExprOpt(w, fields, names, selfTy),
          body = sfExprT(body, fields, names, selfTy)
        )
      )
    }
    case ELambda(ps, body) -> {
      val names = extendedScope(bound)
      val outPs: List[LambdaParam] = newList()
      for p in ps {
        names.add(p.name)
        outPs.add(p.copy(ty = withoutSelfTypeOpt(p.ty, selfTy)))
      }
      e.copy(kind = ELambda(lambdaParams = outPs, body = sfBlock(body, fields, names, selfTy)))
    }
    case ECall(f, args) -> {
      val acc: List[CallArg] = newList()
      for a in args {
        acc.add(sfCallArg(a, fields, bound, selfTy))
      }
      e.copy(kind = ECall(fn = sfCallee(f, fields, bound, selfTy), args = acc))
    }
    case ETypeApp(f, targs) -> e.copy(kind = ETypeApp(fn = sfExprT(f, fields, bound, selfTy), args = targs))
    case EIndex(r, idx) -> e.copy(
      kind = EIndex(
        receiver = sfExprT(r, fields, bound, selfTy),
        indices = sfExprs(idx, fields, bound, selfTy)
      )
    )
    case EMember(r, m) -> e.copy(kind = EMember(receiver = sfExprT(r, fields, bound, selfTy), memberName = m))
    case EPropagate(x) -> e.copy(kind = EPropagate(inner = sfExprT(x, fields, bound, selfTy)))
    case EPrefix(op, x) -> e.copy(kind = EPrefix(op = op, operand = sfExprT(x, fields, bound, selfTy)))
    case EBinop(op, l, r) -> e.copy(
      kind = EBinop(
        op = op,
        lhs = sfExprT(l, fields, bound, selfTy),
        rhs = sfExprT(r, fields, bound, selfTy)
      )
    )
    case ERange(rb) -> e.copy(kind = ERange(bound = sfRange(rb, fields, bound, selfTy)))
    case EAssign(t, op, v) -> e.copy(
      kind = EAssign(
        target = sfExprT(t, fields, bound, selfTy),
        op = op,
        value = sfExprT(v, fields, bound, selfTy)
      )
    )
    case EBlock(b) -> e.copy(kind = EBlock(block = sfBlock(b, fields, bound, selfTy)))
    case EUnsafe(b) -> e.copy(kind = EUnsafe(block = sfBlock(b, fields, bound, selfTy)))
    case _ -> e
  }
}

func sfSegment(
  s: in InterpolatedSegment, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr
): InterpolatedSegment {
  match s {
    case ISExpr(x) -> ISExpr(expr = sfExprT(x, fields, bound, selfTy))
    case ISText(_, _) -> s
  }
}

func sfEobOpt(
  x: in Option[ExprOrBlock], fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr
): Option[ExprOrBlock] {
  match x {
    case Some(b) -> Some(value = sfEob(b, fields, bound, selfTy))
    case None -> None
  }
}

func sfCallArg(a: in CallArg, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): CallArg {
  match a {
    case CANamed(n, v, sp) -> CANamed(name = n, value = sfExprT(v, fields, bound, selfTy), span = sp)
    case CAPositional(x) -> CAPositional(expr = sfExprT(x, fields, bound, selfTy))
  }
}

func sfRange(rb: in RangeBound, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): RangeBound {
  match rb {
    case RBClosed(lo, hi) -> RBClosed(lo = sfExprT(lo, fields, bound, selfTy), hi = sfExprT(hi, fields, bound, selfTy))
    case RBHalfOpen(lo, hi, dd) -> RBHalfOpen(
      lo = sfExprT(lo, fields, bound, selfTy),
      hi = sfExprT(hi, fields, bound, selfTy),
      bareDotDot = dd
    )
    case _ -> rb
  }
}

func binderScope(bound: in List[String], bs: in List[PropertyBinder]): List[String] {
  val names = extendedScope(bound)
  for b in bs {
    names.add(b.name)
  }
  names
}

func sfArm(a: in MatchArm, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): MatchArm {
  val names = extendedScope(bound)
  patternBinderNames(a.pattern, names)
  a.copy(guard = sfExprOpt(a.guard, fields, names, selfTy), body = sfEob(a.body, fields, names, selfTy))
}

/// Adds every name `p` binds to `acc`.
func patternBinderNames(p: in Pattern, acc: in List[String]): Unit {
  match p.kind {
    case PBinding(n, inner) -> {
      acc.add(n)
      match inner {
        case Some(ip) -> patternBinderNames(ip, acc)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> patternListBinderNames(args, acc)
    case PRecord(_, fs, _) -> {
      for f in fs {
        recordPatternFieldBinders(f, acc)
      }
    }
    case PTuple(ps) -> patternListBinderNames(ps, acc)
    case PParen(x) -> patternBinderNames(x, acc)
    case PTypeTest(x, _) -> patternBinderNames(x, acc)
    case POr(ps) -> patternListBinderNames(ps, acc)
    case _ -> ()
  }
}

func patternListBinderNames(ps: in List[Pattern], acc: in List[String]): Unit {
  for x in ps {
    patternBinderNames(x, acc)
  }
}

func recordPatternFieldBinders(f: in RecordPatternField, acc: in List[String]): Unit {
  match f {
    case RPFNamed(_, p, _) -> patternBinderNames(p, acc)
    case RPFShort(n, _) -> acc.add(n)
  }
}

/// Rewrites one statement of a block; a binding it introduces is added to the
/// block's `names`, so it shadows a field for the statements after it.
func sfStmt(s: in Statement, fields: in Map[String, Bool], names: in List[String], selfTy: in TypeExpr): Statement {
  match s.kind {
    case SLocal(b) -> match b {
      case LBVal(pat, ty, init) -> {
        val init2 = sfExprT(init, fields, names, selfTy)
        patternBinderNames(pat, names)
        s.copy(kind = SLocal(binding = LBVal(pat = pat, ty = withoutSelfTypeOpt(ty, selfTy), init = init2)))
      }
      case LBVar(n, ty, init) -> {
        val init2 = sfExprOpt(init, fields, names, selfTy)
        names.add(n)
        s.copy(kind = SLocal(binding = LBVar(name = n, ty = withoutSelfTypeOpt(ty, selfTy), init = init2)))
      }
      case LBLet(n, ty, init) -> {
        val init2 = sfExprT(init, fields, names, selfTy)
        names.add(n)
        s.copy(kind = SLocal(binding = LBLet(name = n, ty = withoutSelfTypeOpt(ty, selfTy), init = init2)))
      }
    }
    case SAssign(t, op, v) -> s.copy(
      kind = SAssign(
        target = sfExprT(t, fields, names, selfTy),
        op = op,
        value = sfExprT(v, fields, names, selfTy)
      )
    )
    case SReturn(v) -> s.copy(kind = SReturn(value = sfExprOpt(v, fields, names, selfTy)))
    case SThrow(x) -> s.copy(kind = SThrow(expr = sfExprT(x, fields, names, selfTy)))
    case STry(body, catches, fin) -> {
      val cs: List[CatchClause] = newList()
      for c in catches {
        cs.add(sfCatch(c, fields, names, selfTy))
      }
      s.copy(
        kind = STry(
          body = sfBlock(body, fields, names, selfTy),
          catches = cs,
          finally_ = sfBlockOpt(fin, fields, names, selfTy)
        )
      )
    }
    case SDefer(b) -> s.copy(kind = SDefer(body = sfBlock(b, fields, names, selfTy)))
    case SScope(n, b) -> s.copy(kind = SScope(binding = n, body = sfBlock(b, fields, scopeWithName(names, n), selfTy)))
    case SFor(l, pat, iter, body) -> {
      val iter2 = sfExprT(iter, fields, names, selfTy)
      val inner = extendedScope(names)
      patternBinderNames(pat, inner)
      s.copy(kind = SFor(label = l, pat = pat, iter = iter2, body = sfBlock(body, fields, inner, selfTy)))
    }
    case SWhile(l, c, body) -> s.copy(
      kind = SWhile(
        label = l,
        cond = sfExprT(c, fields, names, selfTy),
        body = sfBlock(body, fields, names, selfTy)
      )
    )
    case SLoop(l, body) -> s.copy(kind = SLoop(label = l, body = sfBlock(body, fields, names, selfTy)))
    case SInvariant(x) -> s.copy(kind = SInvariant(expr = sfExprT(x, fields, names, selfTy)))
    case SExpr(x) -> s.copy(kind = SExpr(expr = sfExprT(x, fields, names, selfTy)))
    case SRule(l, r) -> s.copy(
      kind = SRule(lhs = sfExprT(l, fields, names, selfTy), rhs = sfExprT(r, fields, names, selfTy))
    )
    case SItem(it) -> sfNestedItem(s, it, fields, names, selfTy)
    case _ -> s
  }
}

func scopeWithName(names: in List[String], n: in Option[String]): List[String] {
  match n {
    case Some(name) -> {
      val inner = extendedScope(names)
      inner.add(name)
      inner
    }
    case None -> names
  }
}

func sfBlockOpt(
  b: in Option[Block], fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr
): Option[Block] {
  match b {
    case Some(x) -> Some(value = sfBlock(x, fields, bound, selfTy))
    case None -> None
  }
}

func sfCatch(c: in CatchClause, fields: in Map[String, Bool], bound: in List[String], selfTy: in TypeExpr): CatchClause {
  c.copy(body = sfBlock(c.body, fields, scopeWithName(bound, c.bindName), selfTy))
}

/// A function declared inside a method body sees the method's fields through
/// its own parameters and locals like any other names.
func sfNestedItem(
  s: in Statement,
  it: in Item,
  fields: in Map[String, Bool],
  names: in List[String],
  selfTy: in TypeExpr,
): Statement {
  match it.kind {
    case IFunc(fd) -> {
      names.add(fd.name)
      val inner = extendedScope(names)
      for p in fd.params {
        inner.add(p.name)
      }
      val body = match fd.body { case Some(b) -> Some(value = sfFunctionBody(b, fields, inner, selfTy)); case None -> None }
      s.copy(kind = SItem(item = it.copy(kind = IFunc(decl = fd.copy(body = body)))))
    }
    case _ -> s
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Contract metadata keeps value parameters (D173 item 2).  On a target that
// erases them, the emitted file names `Vec` where the source named `Vec[3]`,
// and another package must read the instance type.  `postMono` with each
// value-generic record as written in `preMono` and each declared type that
// erasure shortened (fewer generic arguments than written) restored; the
// rest of each item, a parameter default's lowering included, is kept.
// ─────────────────────────────────────────────────────────────────────────────
pub func withValueRecordsAsWritten(preMono: in SourceFile, postMono: in SourceFile): SourceFile {
  val preItems: Map[String, Item] = newMap()
  for it in preMono.items {
    val key = contractShapeKey(it)
    if key.length > 0 and not preItems.containsKey(key) {
      preItems.add(key, it)
    }
  }
  val items: List[Item] = newList()
  for it in postMono.items {
    match mapGet(preItems, contractShapeKey(it)) {
      case Some(pre) -> items.add(itemAsWritten(pre, it))
      case None -> items.add(it)
    }
  }
  postMono.copy(items = items)
}

func contractShapeKey(it: in Item): String {
  match it.kind {
    case IFunc(d) -> "f:" + d.name + "/" + toString(d.params.count)
    case IRecord(d) -> "r:" + d.name
    case IExposedRec(d) -> "x:" + d.name
    case IUnion(d) -> "u:" + d.name
    case _ -> ""
  }
}

func itemAsWritten(pre: in Item, post: in Item): Item {
  match pre.kind {
    case IRecord(pd) -> if recordHasValueGenerics(pd) {
      pre
    } else {
      match post.kind {
        case IRecord(d) -> post.copy(kind = IRecord(decl = recordTypesAsWritten(pd, d)))
        case _ -> post
      }
    }
    case IExposedRec(pd) -> if recordHasValueGenerics(pd) {
      pre
    } else {
      match post.kind {
        case IExposedRec(d) -> post.copy(kind = IExposedRec(decl = recordTypesAsWritten(pd, d)))
        case _ -> post
      }
    }
    case IFunc(pd) -> match post.kind {
      case IFunc(d) -> post.copy(kind = IFunc(decl = funcTypesAsWritten(pd, d)))
      case _ -> post
    }
    case IUnion(pd) -> match post.kind {
      case IUnion(d) -> post.copy(kind = IUnion(decl = unionTypesAsWritten(pd, d)))
      case _ -> post
    }
    case _ -> post
  }
}

/// `written` where erasure shortened `emitted`, else `emitted`.
func typeAsWritten(written: in TypeExpr, emitted: in TypeExpr): TypeExpr {
  if genericArgCount(written) > genericArgCount(emitted) {
    written
  } else {
    emitted
  }
}

func genericArgCount(te: in TypeExpr): Int {
  match te.kind {
    case TGenericApp(_, args) -> {
      var n = args.count
      for a in args {
        n = n + typeArgGenericCount(a)
      }
      n
    }
    case TArray(_, el) -> genericArgCount(el)
    case TSlice(el) -> genericArgCount(el)
    case TNullable(inner) -> genericArgCount(inner)
    case TParen(inner) -> genericArgCount(inner)
    case TTuple(ts) -> genericArgCountOf(ts)
    case TFunction(ps, r) -> genericArgCountOf(ps) + genericArgCount(r)
    case _ -> 0
  }
}

func typeArgGenericCount(a: in TypeArg): Int {
  match a {
    case TAType(t) -> genericArgCount(t)
    case TAValue(_) -> 0
  }
}

func genericArgCountOf(ts: in List[TypeExpr]): Int {
  var n = 0
  for t in ts {
    n = n + genericArgCount(t)
  }
  n
}

func funcTypesAsWritten(pre: in FunctionDecl, post: in FunctionDecl): FunctionDecl {
  if pre.params.count != post.params.count {
    return post
  }
  val params: List[Param] = newList()
  var i = 0
  while i < post.params.count {
    params.add(post.params[i].copy(ty = typeAsWritten(pre.params[i].ty, post.params[i].ty)))
    i = i + 1
  }
  val ret = match post.ret {
    case Some(r) -> match pre.ret {
      case Some(pr) -> Some(value = typeAsWritten(pr, r))
      case None -> post.ret
    }
    case None -> None
  }
  post.copy(params = params, ret = ret)
}

func recordTypesAsWritten(pre: in RecordDecl, post: in RecordDecl): RecordDecl {
  val preFields: Map[String, TypeExpr] = newMap()
  val preMethods: Map[String, FunctionDecl] = newMap()
  for m in pre.members {
    match m {
      case RMField(f) -> if not preFields.containsKey(f.name) { preFields.add(f.name, f.ty) }
      case RMFunc(fn) -> {
        val key = fn.name + "/" + toString(fn.params.count)
        if not preMethods.containsKey(key) {
          preMethods.add(key, fn)
        }
      }
      case _ -> ()
    }
  }
  val members: List[RecordMember] = newList()
  for m in post.members {
    match m {
      case RMField(f) -> match mapGet(preFields, f.name) {
        case Some(pt) -> members.add(RMField(field = f.copy(ty = typeAsWritten(pt, f.ty))))
        case None -> members.add(m)
      }
      case RMFunc(fn) -> match mapGet(preMethods, fn.name + "/" + toString(fn.params.count)) {
        case Some(pfn) -> members.add(RMFunc(fn = funcTypesAsWritten(pfn, fn)))
        case None -> members.add(m)
      }
      case _ -> members.add(m)
    }
  }
  post.copy(members = members)
}

func unionTypesAsWritten(pre: in UnionDecl, post: in UnionDecl): UnionDecl {
  val preCases: Map[String, UnionCase] = newMap()
  for c in pre.cases {
    if not preCases.containsKey(c.name) {
      preCases.add(c.name, c)
    }
  }
  val cases: List[UnionCase] = newList()
  for c in post.cases {
    match mapGet(preCases, c.name) {
      case Some(pc) -> cases.add(c.copy(fields = unionFieldsAsWritten(pc.fields, c.fields)))
      case None -> cases.add(c)
    }
  }
  post.copy(cases = cases)
}

func unionFieldsAsWritten(pre: in List[UnionField], post: in List[UnionField]): List[UnionField] {
  if pre.count != post.count {
    return post
  }
  val acc: List[UnionField] = newList()
  var i = 0
  while i < post.count {
    acc.add(unionFieldAsWritten(pre[i], post[i]))
    i = i + 1
  }
  acc
}

func unionFieldAsWritten(pre: in UnionField, post: in UnionField): UnionField {
  val pt = match pre { case UFNamed(_, t, _) -> t; case UFPos(t, _) -> t }
  match post {
    case UFNamed(n, t, sp) -> UFNamed(name = n, ty = typeAsWritten(pt, t), span = sp)
    case UFPos(t, sp) -> UFPos(ty = typeAsWritten(pt, t), span = sp)
  }
}
