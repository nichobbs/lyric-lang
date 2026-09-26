//! A post-order expression rewriter over a whole source file: every
//! expression reachable from a function, method, entry, test, `val`,
//! `const` or field default is rebuilt bottom-up and then passed to `f`,
//! whose result replaces it.  Patterns and types are left untouched, and
//! contract clauses are too unless the mapper opts in (`contracts`).
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

/// The callbacks of a traversal: `expr` sees every expression bottom-up,
/// `stmt` every statement after its parts have been rebuilt.
pub record AstMapper {
  expr: (Expr) -> Expr
  stmt: (Statement) -> Statement
  /// Also rewrite `requires:`/`ensures:`/`when:`/`decreases:` clauses.
  contracts: Bool
}

func exprOnly(f: in (Expr) -> Expr): AstMapper {
  AstMapper(expr = f, stmt = { s: Statement -> s }, contracts = false)
}

/// `mapExprsInFile` and `mapStmtsInFile` in one pass, contract clauses
/// included.
pub func mapFileAndContracts(file: in SourceFile, f: in (Expr) -> Expr, g: in (Statement) -> Statement): SourceFile {
  mapFileWith(file, AstMapper(expr = f, stmt = g, contracts = true))
}

pub func mapExprsInFile(file: in SourceFile, f: in (Expr) -> Expr): SourceFile {
  mapFileWith(file, exprOnly(f))
}

/// A post-order statement rewriter over the same reach as `mapExprsInFile`:
/// each statement is passed to `g` after its sub-statements and expressions
/// have been rebuilt, and `g`'s result replaces it.
pub func mapStmtsInFile(file: in SourceFile, g: in (Statement) -> Statement): SourceFile {
  mapFileWith(file, AstMapper(expr = { e: Expr -> e }, stmt = g, contracts = false))
}

pub func mapExpr(e: in Expr, f: in (Expr) -> Expr): Expr {
  mapExprWith(e, exprOnly(f))
}

pub func mapBlock(blk: in Block, f: in (Expr) -> Expr): Block {
  mapBlockWith(blk, exprOnly(f))
}

func mapFileWith(file: in SourceFile, m: in AstMapper): SourceFile {
  val items: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    items.add(mapItem(file.items[i], m))
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

func mapItem(it: in Item, m: in AstMapper): Item {
  val kind: ItemKind = match it.kind {
    case IFunc(fn) -> IFunc(decl = mapFunction(fn, m))
    case IRecord(decl) -> IRecord(decl = mapRecordDecl(decl, m))
    case IExposedRec(decl) -> IExposedRec(decl = mapRecordDecl(decl, m))
    case IOpaque(decl) -> {
      val members: List[OpaqueMember] = newList()
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case OMField(fd) -> members.add(OMField(field = mapFieldDecl(fd, m)))
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
          case IMplFunc(fn) -> members.add(IMplFunc(fn = mapFunction(fn, m)))
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
          case IMFunc(fn) -> members.add(IMFunc(fn = mapFunction(fn, m)))
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
                contracts = mapContracts(ed.contracts, m),
                body = mapFunctionBody(ed.body, m),
                span = ed.span
              )
            )
          )
          case PMFunc(fn) -> members.add(PMFunc(fn = mapFunction(fn, m)))
          case PMField(pf) -> members.add(PMField(field = mapProtectedField(pf, m)))
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
        init = mapExprWith(decl.init, m),
        span = decl.span
      )
    )
    case IConst(decl) -> IConst(
      decl = ConstDecl(
        name = decl.name,
        ty = decl.ty,
        init = mapExprWith(decl.init, m),
        span = decl.span
      )
    )
    case ITest(decl) -> ITest(
      decl = TestDecl(
        title = decl.title,
        body = mapBlockWith(decl.body, m),
        span = decl.span
      )
    )
    case IProperty(decl) -> IProperty(
      decl = PropertyDecl(
        title = decl.title,
        forAll = decl.forAll,
        guardExpr = mapExprOpt(decl.guardExpr, m),
        body = mapBlockWith(decl.body, m),
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

func mapRecordDecl(decl: in RecordDecl, m: in AstMapper): RecordDecl {
  val members: List[RecordMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(fd) -> members.add(RMField(field = mapFieldDecl(fd, m)))
      case RMFunc(fn) -> members.add(RMFunc(fn = mapFunction(fn, m)))
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

func mapFieldDecl(fd: in FieldDecl, m: in AstMapper): FieldDecl {
  FieldDecl(
    docComments = fd.docComments,
    annotations = fd.annotations,
    visibility = fd.visibility,
    isMutable = fd.isMutable,
    name = fd.name,
    ty = fd.ty,
    dflt = mapExprOpt(fd.dflt, m),
    span = fd.span,
    trailingAnnotationCount = fd.trailingAnnotationCount
  )
}

func mapProtectedField(pf: in ProtectedField, m: in AstMapper): ProtectedField {
  match pf {
    case PFVar(n, ty, init, docs, anns, sp) -> PFVar(
      name = n,
      ty = ty,
      init = mapExprOpt(init, m),
      docComments = docs,
      annotations = anns,
      span = sp
    )
    case PFLet(n, ty, init, docs, anns, sp) -> PFLet(
      name = n,
      ty = ty,
      init = mapExprOpt(init, m),
      docComments = docs,
      annotations = anns,
      span = sp
    )
    case PFImmutable(fd) -> PFImmutable(field = mapFieldDecl(fd, m))
  }
}

func mapFunction(fn: in FunctionDecl, m: in AstMapper): FunctionDecl {
  val body: Option[FunctionBody] = match fn.body {
    case Some(b) -> Some(value = mapFunctionBody(b, m))
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
    contracts = mapContracts(fn.contracts, m),
    body = body,
    span = fn.span
  )
}

func mapContracts(cs: in List[ContractClause], m: in AstMapper): List[ContractClause] {
  if not m.contracts {
    return cs
  }
  val mapped: List[ContractClause] = newList()
  var i = 0
  while i < cs.count {
    mapped.add(
      match cs[i] {
        case CCRequires(e, sp) -> CCRequires(expr = mapExprWith(e, m), span = sp)
        case CCEnsures(e, sp) -> CCEnsures(expr = mapExprWith(e, m), span = sp)
        case CCWhen(e, sp) -> CCWhen(expr = mapExprWith(e, m), span = sp)
        case CCDecreases(e, sp) -> CCDecreases(expr = mapExprWith(e, m), span = sp)
        case other -> other
      }
    )
    i = i + 1
  }
  mapped
}

func mapFunctionBody(b: in FunctionBody, m: in AstMapper): FunctionBody {
  match b {
    case FBExpr(e) -> FBExpr(expr = mapExprWith(e, m))
    case FBBlock(blk) -> FBBlock(block = mapBlockWith(blk, m))
  }
}

func mapExprOpt(eo: in Option[Expr], m: in AstMapper): Option[Expr] {
  match eo {
    case Some(e) -> Some(value = mapExprWith(e, m))
    case None -> None
  }
}

func mapExprList(xs: in List[Expr], m: in AstMapper): List[Expr] {
  val acc: List[Expr] = newList()
  var i = 0
  while i < xs.count {
    acc.add(mapExprWith(xs[i], m))
    i = i + 1
  }
  acc
}

func mapEob(eob: in ExprOrBlock, m: in AstMapper): ExprOrBlock {
  match eob {
    case EOBExpr(e) -> EOBExpr(expr = mapExprWith(e, m))
    case EOBBlock(blk) -> EOBBlock(block = mapBlockWith(blk, m))
  }
}

func mapRange(rb: in RangeBound, m: in AstMapper): RangeBound {
  match rb {
    case RBClosed(lo, hi) -> RBClosed(lo = mapExprWith(lo, m), hi = mapExprWith(hi, m))
    case RBHalfOpen(lo, hi, bare) -> RBHalfOpen(lo = mapExprWith(lo, m), hi = mapExprWith(hi, m), bareDotDot = bare)
    case RBLowerOpen(hi) -> RBLowerOpen(hi = mapExprWith(hi, m))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = mapExprWith(lo, m))
  }
}

func mapExprWith(e: in Expr, m: in AstMapper): Expr {
  val sp = e.span
  val rebuilt: Expr = match e.kind {
    case EInterpolated(segs) -> {
      val acc: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, tsp) -> acc.add(ISText(text = t, span = tsp))
          case ISExpr(x) -> acc.add(ISExpr(expr = mapExprWith(x, m)))
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = acc), sp)
    }
    case EParen(inner) -> mkExpr(EParen(inner = mapExprWith(inner, m)), sp)
    case ETuple(xs) -> mkExpr(ETuple(exprs = mapExprList(xs, m)), sp)
    case EList(xs) -> mkExpr(EList(exprs = mapExprList(xs, m)), sp)
    case EIf(cond, thenB, elseB, thenForm) -> {
      val newElse: Option[ExprOrBlock] = match elseB { case Some(eb) -> Some(value = mapEob(eb, m)); case None -> None }
      mkExpr(EIf(cond = mapExprWith(cond, m), thenBranch = mapEob(thenB, m), elseBranch = newElse, thenForm = thenForm), sp)
    }
    case EMatch(scrut, arms) -> {
      val acc: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        acc.add(
          MatchArm(pattern = arm.pattern, guard = mapExprOpt(arm.guard, m), body = mapEob(arm.body, m), span = arm.span)
        )
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = mapExprWith(scrut, m), arms = acc), sp)
    }
    case EAwait(inner) -> mkExpr(EAwait(inner = mapExprWith(inner, m)), sp)
    case EYield(inner) -> mkExpr(EYield(inner = mapExprWith(inner, m)), sp)
    case ESpawn(inner) -> mkExpr(ESpawn(inner = mapExprWith(inner, m)), sp)
    case ETry(inner) -> mkExpr(ETry(inner = mapExprWith(inner, m)), sp)
    case EOld(inner) -> mkExpr(EOld(inner = mapExprWith(inner, m)), sp)
    case EForall(bs, w, body) -> mkExpr(
      EForall(
        binders = bs,
        whereExpr = mapExprOpt(w, m),
        body = mapExprWith(body, m)
      ),
      sp
    )
    case EExists(bs, w, body) -> mkExpr(
      EExists(
        binders = bs,
        whereExpr = mapExprOpt(w, m),
        body = mapExprWith(body, m)
      ),
      sp
    )
    case ELambda(ps, body) -> mkExpr(ELambda(lambdaParams = ps, body = mapBlockWith(body, m)), sp)
    case ECall(fn, args) -> {
      val acc: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(n, v, asp) -> acc.add(CANamed(name = n, value = mapExprWith(v, m), span = asp))
          case CAPositional(v) -> acc.add(CAPositional(expr = mapExprWith(v, m)))
        }
        i = i + 1
      }
      mkExpr(ECall(fn = mapExprWith(fn, m), args = acc), sp)
    }
    case ETypeApp(fn, targs) -> mkExpr(ETypeApp(fn = mapExprWith(fn, m), args = targs), sp)
    case EIndex(recv, idx) -> mkExpr(
      EIndex(
        receiver = mapExprWith(recv, m),
        indices = mapExprList(idx, m)
      ),
      sp
    )
    case EMember(recv, mname) -> mkExpr(
      EMember(receiver = mapExprWith(recv, m), memberName = mname),
      sp
    )
    case EPropagate(inner) -> mkExpr(EPropagate(inner = mapExprWith(inner, m)), sp)
    case EPrefix(op, x) -> mkExpr(EPrefix(op = op, operand = mapExprWith(x, m)), sp)
    case EBinop(op, l, r) -> mkExpr(
      EBinop(op = op, lhs = mapExprWith(l, m), rhs = mapExprWith(r, m)),
      sp
    )
    case ERange(rb) -> mkExpr(ERange(bound = mapRange(rb, m)), sp)
    case EAssign(t, op, v) -> mkExpr(
      EAssign(
        target = mapExprWith(t, m),
        op = op,
        value = mapExprWith(v, m)
      ),
      sp
    )
    case EBlock(blk) -> mkExpr(EBlock(block = mapBlockWith(blk, m)), sp)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = mapBlockWith(blk, m)), sp)
    case _ -> e
  }
  val fe = m.expr
  fe(rebuilt)
}

func mapBlockWith(blk: in Block, m: in AstMapper): Block {
  val acc: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    acc.add(mapStmt(blk.statements[i], m))
    i = i + 1
  }
  Block(statements = acc, span = blk.span)
}

func mapBinding(b: in LocalBinding, m: in AstMapper): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = mapExprWith(init, m))
    case LBLet(n, ty, init) -> LBLet(name = n, ty = ty, init = mapExprWith(init, m))
    case LBVar(n, ty, init) -> LBVar(name = n, ty = ty, init = mapExprOpt(init, m))
  }
}

func mapStmt(s: in Statement, m: in AstMapper): Statement {
  val sp = s.span
  val rebuilt = match s.kind {
    case SLocal(b) -> mkStmt(SLocal(binding = mapBinding(b, m)), sp)
    case SAssign(t, op, v) -> mkStmt(
      SAssign(target = mapExprWith(t, m), op = op, value = mapExprWith(v, m)),
      sp
    )
    case SReturn(v) -> mkStmt(SReturn(value = mapExprOpt(v, m)), sp)
    case SThrow(x) -> mkStmt(SThrow(expr = mapExprWith(x, m)), sp)
    case STry(body, catches, fin) -> {
      val acc: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val c = catches[i]
        acc.add(CatchClause(typeName = c.typeName, bindName = c.bindName, body = mapBlockWith(c.body, m), span = c.span))
        i = i + 1
      }
      val newFin: Option[Block] = match fin { case Some(fb) -> Some(value = mapBlockWith(fb, m)); case None -> None }
      mkStmt(STry(body = mapBlockWith(body, m), catches = acc, finally_ = newFin), sp)
    }
    case SDefer(body) -> mkStmt(SDefer(body = mapBlockWith(body, m)), sp)
    case SScope(b, body) -> mkStmt(SScope(binding = b, body = mapBlockWith(body, m)), sp)
    case SFor(label, pat, iter, body) -> mkStmt(
      SFor(
        label = label,
        pat = pat,
        iter = mapExprWith(iter, m),
        body = mapBlockWith(body, m)
      ),
      sp
    )
    case SWhile(label, cond, body) -> mkStmt(
      SWhile(
        label = label,
        cond = mapExprWith(cond, m),
        body = mapBlockWith(body, m)
      ),
      sp
    )
    case SLoop(label, body) -> mkStmt(SLoop(label = label, body = mapBlockWith(body, m)), sp)
    case SInvariant(x) -> mkStmt(SInvariant(expr = mapExprWith(x, m)), sp)
    case SExpr(x) -> mkStmt(SExpr(expr = mapExprWith(x, m)), sp)
    case SRule(l, r) -> mkStmt(SRule(lhs = mapExprWith(l, m), rhs = mapExprWith(r, m)), sp)
    case _ -> s
  }
  val fs = m.stmt
  fs(rebuilt)
}
