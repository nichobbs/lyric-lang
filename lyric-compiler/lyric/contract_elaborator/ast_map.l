//! A post-order expression rewriter over a whole source file: every
//! expression reachable from a function, method, entry, test, `val`,
//! `const` or field default is rebuilt bottom-up and then passed to `f`,
//! whose result replaces it.  Patterns, types and contract clauses are left
//! untouched.  Used by `wrapInvariantConstructions`.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

pub func mapExprsInFile(file: in SourceFile, f: in (Expr) -> Expr): SourceFile {
  val items: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    items.add(mapItem(file.items[i], f))
    i = i + 1
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

func mapItem(it: in Item, f: in (Expr) -> Expr): Item {
  val kind: ItemKind = match it.kind {
    case IFunc(fn) -> IFunc(decl = mapFunction(fn, f))
    case IRecord(decl) -> IRecord(decl = mapRecordDecl(decl, f))
    case IExposedRec(decl) -> IExposedRec(decl = mapRecordDecl(decl, f))
    case IOpaque(decl) -> {
      val members: List[OpaqueMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case OMField(fd) -> members.add(OMField(field = mapFieldDecl(fd, f)))
          case other -> members.add(other)
        }
        i = i + 1
      }
      IOpaque(
        decl = OpaqueTypeDecl(
          name = decl.name,
          generics = decl.generics,
          whereClause = decl.whereClause,
          annotations = decl.annotations,
          members = members,
          hasBody = decl.hasBody,
          span = decl.span
        )
      )
    }
    case IImpl(decl) -> {
      val members: List[ImplMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> members.add(IMplFunc(fn = mapFunction(fn, f)))
          case other -> members.add(other)
        }
        i = i + 1
      }
      IImpl(
        decl = ImplDecl(
          generics = decl.generics,
          iface = decl.iface,
          target = decl.target,
          whereClause = decl.whereClause,
          members = members,
          span = decl.span
        )
      )
    }
    case IInterface(decl) -> {
      val members: List[InterfaceMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMFunc(fn) -> members.add(IMFunc(fn = mapFunction(fn, f)))
          case other -> members.add(other)
        }
        i = i + 1
      }
      IInterface(
        decl = InterfaceDecl(
          name = decl.name,
          generics = decl.generics,
          whereClause = decl.whereClause,
          members = members,
          span = decl.span
        )
      )
    }
    case IProtected(decl) -> {
      val members: List[ProtectedMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMEntry(ed) -> members.add(
            PMEntry(
              entryDecl = EntryDecl(
                docComments = ed.docComments,
                annotations = ed.annotations,
                visibility = ed.visibility,
                name = ed.name,
                params = ed.params,
                ret = ed.ret,
                contracts = ed.contracts,
                body = mapFunctionBody(ed.body, f),
                span = ed.span
              )
            )
          )
          case PMFunc(fn) -> members.add(PMFunc(fn = mapFunction(fn, f)))
          case PMField(pf) -> members.add(PMField(field = mapProtectedField(pf, f)))
          case other -> members.add(other)
        }
        i = i + 1
      }
      IProtected(
        decl = ProtectedTypeDecl(
          name = decl.name,
          generics = decl.generics,
          whereClause = decl.whereClause,
          members = members,
          span = decl.span
        )
      )
    }
    case IVal(decl) -> IVal(
      decl = ValDecl(
        pattern = decl.pattern,
        ty = decl.ty,
        init = mapExpr(decl.init, f),
        span = decl.span
      )
    )
    case IConst(decl) -> IConst(
      decl = ConstDecl(
        name = decl.name,
        ty = decl.ty,
        init = mapExpr(decl.init, f),
        span = decl.span
      )
    )
    case ITest(decl) -> ITest(
      decl = TestDecl(
        title = decl.title,
        body = mapBlock(decl.body, f),
        span = decl.span
      )
    )
    case IProperty(decl) -> IProperty(
      decl = PropertyDecl(
        title = decl.title,
        forAll = decl.forAll,
        guardExpr = mapExprOpt(decl.guardExpr, f),
        body = mapBlock(decl.body, f),
        span = decl.span
      )
    )
    case other -> other
  }
  Item(
    docComments = it.docComments,
    annotations = it.annotations,
    visibility = it.visibility,
    kind = kind,
    span = it.span
  )
}

func mapRecordDecl(decl: in RecordDecl, f: in (Expr) -> Expr): RecordDecl {
  val members: List[RecordMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(fd) -> members.add(RMField(field = mapFieldDecl(fd, f)))
      case RMFunc(fn) -> members.add(RMFunc(fn = mapFunction(fn, f)))
      case other -> members.add(other)
    }
    i = i + 1
  }
  RecordDecl(
    name = decl.name,
    generics = decl.generics,
    whereClause = decl.whereClause,
    members = members,
    span = decl.span
  )
}

func mapFieldDecl(fd: in FieldDecl, f: in (Expr) -> Expr): FieldDecl {
  FieldDecl(
    docComments = fd.docComments,
    annotations = fd.annotations,
    visibility = fd.visibility,
    isMutable = fd.isMutable,
    name = fd.name,
    ty = fd.ty,
    dflt = mapExprOpt(fd.dflt, f),
    span = fd.span,
    trailingAnnotationCount = fd.trailingAnnotationCount
  )
}

func mapProtectedField(pf: in ProtectedField, f: in (Expr) -> Expr): ProtectedField {
  match pf {
    case PFVar(n, ty, init, docs, anns, sp) -> PFVar(
      name = n,
      ty = ty,
      init = mapExprOpt(init, f),
      docComments = docs,
      annotations = anns,
      span = sp
    )
    case PFLet(n, ty, init, docs, anns, sp) -> PFLet(
      name = n,
      ty = ty,
      init = mapExprOpt(init, f),
      docComments = docs,
      annotations = anns,
      span = sp
    )
    case PFImmutable(fd) -> PFImmutable(field = mapFieldDecl(fd, f))
  }
}

func mapFunction(fn: in FunctionDecl, f: in (Expr) -> Expr): FunctionDecl {
  val body: Option[FunctionBody] = match fn.body {
    case Some(b) -> Some(value = mapFunctionBody(b, f))
    case None -> None
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = body,
    span = fn.span
  )
}

func mapFunctionBody(b: in FunctionBody, f: in (Expr) -> Expr): FunctionBody {
  match b {
    case FBExpr(e) -> FBExpr(expr = mapExpr(e, f))
    case FBBlock(blk) -> FBBlock(block = mapBlock(blk, f))
  }
}

func mapExprOpt(eo: in Option[Expr], f: in (Expr) -> Expr): Option[Expr] {
  match eo {
    case Some(e) -> Some(value = mapExpr(e, f))
    case None -> None
  }
}

func mapExprList(xs: in List[Expr], f: in (Expr) -> Expr): List[Expr] {
  val acc: List[Expr] = newList()
  var i = 0
  while i < xs.count {
    acc.add(mapExpr(xs[i], f))
    i = i + 1
  }
  acc
}

func mapEob(eob: in ExprOrBlock, f: in (Expr) -> Expr): ExprOrBlock {
  match eob {
    case EOBExpr(e) -> EOBExpr(expr = mapExpr(e, f))
    case EOBBlock(blk) -> EOBBlock(block = mapBlock(blk, f))
  }
}

func mapRange(rb: in RangeBound, f: in (Expr) -> Expr): RangeBound {
  match rb {
    case RBClosed(lo, hi) -> RBClosed(lo = mapExpr(lo, f), hi = mapExpr(hi, f))
    case RBHalfOpen(lo, hi, bare) -> RBHalfOpen(lo = mapExpr(lo, f), hi = mapExpr(hi, f), bareDotDot = bare)
    case RBLowerOpen(hi) -> RBLowerOpen(hi = mapExpr(hi, f))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = mapExpr(lo, f))
  }
}

pub func mapExpr(e: in Expr, f: in (Expr) -> Expr): Expr {
  val sp = e.span
  val rebuilt: Expr = match e.kind {
    case EInterpolated(segs) -> {
      val acc: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, tsp) -> acc.add(ISText(text = t, span = tsp))
          case ISExpr(x) -> acc.add(ISExpr(expr = mapExpr(x, f)))
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = acc), sp)
    }
    case EParen(inner) -> mkExpr(EParen(inner = mapExpr(inner, f)), sp)
    case ETuple(xs) -> mkExpr(ETuple(exprs = mapExprList(xs, f)), sp)
    case EList(xs) -> mkExpr(EList(exprs = mapExprList(xs, f)), sp)
    case EIf(cond, thenB, elseB, thenForm) -> {
      val newElse: Option[ExprOrBlock] = match elseB { case Some(eb) -> Some(value = mapEob(eb, f)); case None -> None }
      mkExpr(EIf(cond = mapExpr(cond, f), thenBranch = mapEob(thenB, f), elseBranch = newElse, thenForm = thenForm), sp)
    }
    case EMatch(scrut, arms) -> {
      val acc: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        acc.add(
          MatchArm(pattern = arm.pattern, guard = mapExprOpt(arm.guard, f), body = mapEob(arm.body, f), span = arm.span)
        )
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = mapExpr(scrut, f), arms = acc), sp)
    }
    case EAwait(inner) -> mkExpr(EAwait(inner = mapExpr(inner, f)), sp)
    case EYield(inner) -> mkExpr(EYield(inner = mapExpr(inner, f)), sp)
    case ESpawn(inner) -> mkExpr(ESpawn(inner = mapExpr(inner, f)), sp)
    case ETry(inner) -> mkExpr(ETry(inner = mapExpr(inner, f)), sp)
    case EOld(inner) -> mkExpr(EOld(inner = mapExpr(inner, f)), sp)
    case EForall(bs, w, body) -> mkExpr(
      EForall(
        binders = bs,
        whereExpr = mapExprOpt(w, f),
        body = mapExpr(body, f)
      ),
      sp
    )
    case EExists(bs, w, body) -> mkExpr(
      EExists(
        binders = bs,
        whereExpr = mapExprOpt(w, f),
        body = mapExpr(body, f)
      ),
      sp
    )
    case ELambda(ps, body) -> mkExpr(ELambda(lambdaParams = ps, body = mapBlock(body, f)), sp)
    case ECall(fn, args) -> {
      val acc: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(n, v, asp) -> acc.add(CANamed(name = n, value = mapExpr(v, f), span = asp))
          case CAPositional(v) -> acc.add(CAPositional(expr = mapExpr(v, f)))
        }
        i = i + 1
      }
      mkExpr(ECall(fn = mapExpr(fn, f), args = acc), sp)
    }
    case ETypeApp(fn, targs) -> mkExpr(ETypeApp(fn = mapExpr(fn, f), args = targs), sp)
    case EIndex(recv, idx) -> mkExpr(
      EIndex(receiver = mapExpr(recv, f), indices = mapExprList(idx, f)),
      sp
    )
    case EMember(recv, m) -> mkExpr(EMember(receiver = mapExpr(recv, f), memberName = m), sp)
    case EPropagate(inner) -> mkExpr(EPropagate(inner = mapExpr(inner, f)), sp)
    case EPrefix(op, x) -> mkExpr(EPrefix(op = op, operand = mapExpr(x, f)), sp)
    case EBinop(op, l, r) -> mkExpr(EBinop(op = op, lhs = mapExpr(l, f), rhs = mapExpr(r, f)), sp)
    case ERange(rb) -> mkExpr(ERange(bound = mapRange(rb, f)), sp)
    case EAssign(t, op, v) -> mkExpr(
      EAssign(target = mapExpr(t, f), op = op, value = mapExpr(v, f)),
      sp
    )
    case EBlock(blk) -> mkExpr(EBlock(block = mapBlock(blk, f)), sp)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = mapBlock(blk, f)), sp)
    case _ -> e
  }
  f(rebuilt)
}

pub func mapBlock(blk: in Block, f: in (Expr) -> Expr): Block {
  val acc: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    acc.add(mapStmt(blk.statements[i], f))
    i = i + 1
  }
  Block(statements = acc, span = blk.span)
}

func mapBinding(b: in LocalBinding, f: in (Expr) -> Expr): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = mapExpr(init, f))
    case LBLet(n, ty, init) -> LBLet(name = n, ty = ty, init = mapExpr(init, f))
    case LBVar(n, ty, init) -> LBVar(name = n, ty = ty, init = mapExprOpt(init, f))
  }
}

func mapStmt(s: in Statement, f: in (Expr) -> Expr): Statement {
  val sp = s.span
  match s.kind {
    case SLocal(b) -> mkStmt(SLocal(binding = mapBinding(b, f)), sp)
    case SAssign(t, op, v) -> mkStmt(SAssign(target = mapExpr(t, f), op = op, value = mapExpr(v, f)), sp)
    case SReturn(v) -> mkStmt(SReturn(value = mapExprOpt(v, f)), sp)
    case SThrow(x) -> mkStmt(SThrow(expr = mapExpr(x, f)), sp)
    case STry(body, catches, fin) -> {
      val acc: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val c = catches[i]
        acc.add(CatchClause(typeName = c.typeName, bindName = c.bindName, body = mapBlock(c.body, f), span = c.span))
        i = i + 1
      }
      val newFin: Option[Block] = match fin { case Some(fb) -> Some(value = mapBlock(fb, f)); case None -> None }
      mkStmt(STry(body = mapBlock(body, f), catches = acc, finally_ = newFin), sp)
    }
    case SDefer(body) -> mkStmt(SDefer(body = mapBlock(body, f)), sp)
    case SScope(b, body) -> mkStmt(SScope(binding = b, body = mapBlock(body, f)), sp)
    case SFor(label, pat, iter, body) -> mkStmt(
      SFor(
        label = label,
        pat = pat,
        iter = mapExpr(iter, f),
        body = mapBlock(body, f)
      ),
      sp
    )
    case SWhile(label, cond, body) -> mkStmt(
      SWhile(label = label, cond = mapExpr(cond, f), body = mapBlock(body, f)),
      sp
    )
    case SLoop(label, body) -> mkStmt(SLoop(label = label, body = mapBlock(body, f)), sp)
    case SInvariant(x) -> mkStmt(SInvariant(expr = mapExpr(x, f)), sp)
    case SExpr(x) -> mkStmt(SExpr(expr = mapExpr(x, f)), sp)
    case SRule(l, r) -> mkStmt(SRule(lhs = mapExpr(l, f), rhs = mapExpr(r, f)), sp)
    case _ -> s
  }
}
