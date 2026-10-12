//! lyric/self_fields.l — Lyric.SelfFields: the shared, target-independent
//! resolution of a bare field name inside a member body (#8264).
//!
//! A member of a type — a protected `entry`/`func`, a record-body method, or
//! an `impl` method — reads and writes its own type's fields by bare name
//! (`count = count + 1` means `self.count = self.count + 1`, §7.5, #6173).
//! The type checker resolves such a name exactly like an outermost local:
//! the fields are seeded into the member's scope BEFORE its parameters, so a
//! parameter, a `val`/`var`/`let`, a pattern binding (`match` arm, `for`,
//! destructuring `val`), a lambda parameter, a `catch` binding or a
//! quantifier binder of the same name shadows the field for the rest of its
//! own scope, and the field is visible again once that scope ends.
//!
//! This package rewrites every bare reference that resolves to a field into
//! the explicit `self.<name>` form under that same scoping, so a backend
//! never has to decide between a local and a field itself.  Before it, MSIL
//! and native rewrote EVERY bare occurrence of a field name to `self.<name>`
//! regardless of scope, so a local that shadowed a field was ignored and its
//! reads and writes went to the field (#8264).
//!
//! Callers:
//!   * `Lyric.Pipeline.pipeCheckAndMono` runs `resolveSelfFieldsInFile` over
//!     each file after the mode check and before the contract elaborator, on
//!     every target, and each member it resolves is marked with the reserved
//!     `__lyric_self_resolved` annotation.  Every bare name left in a marked
//!     body is a binding or a module-level name — including the bare names of
//!     an interface's contract clause the elaborator later inserts into an
//!     `impl` method, and of an inherited interface default (also marked):
//!     neither sees the target's fields — so codegen's own bare-field
//!     fallback (MSIL `fctx.className`, the JVM `selfFieldType`) is off for a
//!     marked member.
//!   * `Lyric.ContractElaborator` resolves a member's own `requires:`/
//!     `ensures:`/`when:` clauses (against its parameters and the fields)
//!     and its protected type's invariants (against the fields alone) with
//!     `resolveSelfFieldsInExpr` before inserting them: an `ensures:` assert
//!     lands at a return site, where a body local may shadow the field the
//!     clause names.  The violation message keeps the clause as written.
//!   * The MSIL protected-type lowering and `Lyric.LlvmCodegen` resolve again
//!     a member the middle end did not mark (a file it did not process).
package Lyric.SelfFields

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Field sets.
// ─────────────────────────────────────────────────────────────────────────────
func addName(m: in Map[String, Bool], name: in String): Unit {
  if not m.containsKey(name) {
    m.add(name, true)
  }
}

/// The fields a record-body method or an `impl` method of the record sees
/// by bare name.
pub func recordFieldNames(members: in List[RecordMember]): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  for m in members {
    match m {
      case RMField(field) -> addName(names, field.name)
      case _ -> ()
    }
  }
  names
}

/// The fields a protected type's members see by bare name.
pub func protectedFieldNames(members: in List[ProtectedMember]): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  for m in members {
    match m {
      case PMField(field) -> match field {
        case PFVar(name, _, _, _, _, _) -> addName(names, name)
        case PFLet(name, _, _, _, _, _) -> addName(names, name)
        case PFImmutable(fd) -> addName(names, fd.name)
      }
      case _ -> ()
    }
  }
  names
}

/// The `entry` and `func` members of a protected type, by name.
pub func protectedMethodNames(members: in List[ProtectedMember]): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  for m in members {
    match m {
      case PMEntry(ed) -> addName(names, ed.name)
      case PMFunc(fn) -> addName(names, fn.name)
      case _ -> ()
    }
  }
  names
}

func noFields(index: in Map[String, Map[String, Bool]], name: in String): Unit {
  if not index.containsKey(name) {
    val none: Map[String, Bool] = newMap()
    index.add(name, none)
  }
}

/// Type name -> the field names its members see, for every record, exposed
/// record and protected type `file` declares, then for each of
/// `extraRecords` (declared in another file or package) whose name the file
/// does not declare as any type of its own.  Keyed by bare name, as an
/// `impl` target is written; two records of one bare name in different
/// packages of `extraRecords` resolve first-wins, the limitation #7029
/// tracks for `Lyric.HoistEngine`'s index of the same shape.
pub func typeFieldIndex(file: in SourceFile, extraRecords: in List[RecordDecl]): Map[String, Map[String, Bool]] {
  val index: Map[String, Map[String, Bool]] = newMap()
  for it in file.items {
    match it.kind {
      case IRecord(decl) -> {
        if not index.containsKey(decl.name) {
          index.add(decl.name, recordFieldNames(decl.members))
        }
      }
      case IExposedRec(decl) -> {
        if not index.containsKey(decl.name) {
          index.add(decl.name, recordFieldNames(decl.members))
        }
      }
      case IProtected(decl) -> {
        if not index.containsKey(decl.name) {
          index.add(decl.name, protectedFieldNames(decl.members))
        }
      }
      // A type of the file's own with no bare-name fields: an `impl` for it
      // must not take the fields of a record another package names alike.
      case IUnion(decl) -> noFields(index, decl.name)
      case IEnum(decl) -> noFields(index, decl.name)
      case IOpaque(decl) -> noFields(index, decl.name)
      case IDistinctType(decl) -> noFields(index, decl.name)
      case IExternType(decl) -> noFields(index, decl.name)
      case _ -> ()
    }
  }
  for decl in extraRecords {
    if not index.containsKey(decl.name) {
      index.add(decl.name, recordFieldNames(decl.members))
    }
  }
  index
}

/// The fields an `impl ... for <target>` method sees by bare name: the
/// target's own, from `index` (`typeFieldIndex`).  Empty for a target the
/// index does not hold.
pub func implTargetFieldNames(index: in Map[String, Map[String, Bool]], target: in TypeExpr): Map[String, Bool] {
  val segs: List[String] = match target.kind {
    case TRef(path) -> path.segments
    // `impl[T] I for Box[T]`: the fields are `Box`'s.
    case TGenericApp(head, _) -> head.segments
    case _ -> newList()
  }
  if segs.count == 0 {
    return newMap()
  }
  match mapGet(index, segs[segs.count - 1]) {
    case Some(fields) -> fields
    case None -> newMap()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Scopes.
//
// `shadowed` holds the member names a binding in an enclosing scope (a
// parameter, a local, a pattern or lambda binding) hides.  Only member names
// are ever recorded: no other name changes how a bare path resolves here.
// A nested scope works on a copy, so its bindings end with it.
// ─────────────────────────────────────────────────────────────────────────────
/// The names a member body reaches through its implicit receiver: the
/// type's `fields`, and the sibling `methods` a bare call reaches (empty
/// unless the caller lowers such a call as a call on `self`).
record Members {
  fields: Map[String, Bool]
  methods: Map[String, Bool]
  /// The spans (`recordCopySiteKey`) of the bare identifier patterns in
  /// `match` arms the type checker resolved as union or enum cases
  /// (`SymbolTable.casePatternSites`): such a pattern binds nothing.
  caseSites: Map[String, Bool]
}

func isMember(cx: in Members, name: in String): Bool {
  cx.fields.containsKey(name) or cx.methods.containsKey(name)
}

func copyNames(m: in Map[String, Bool]): Map[String, Bool] {
  val acc: Map[String, Bool] = newMap()
  for k in mapKeys(m) {
    acc.add(k, true)
  }
  acc
}

func shadow(cx: in Members, shadowed: in Map[String, Bool], name: in String): Unit {
  if isMember(cx, name) {
    addName(shadowed, name)
  }
}

// `inArm`: `pat` is (part of) a `match` arm's pattern, the only position a
// bare identifier may name a case rather than bind; a `val`, `for` or
// destructuring pattern always binds it.
func shadowPattern(cx: in Members, shadowed: in Map[String, Bool], pat: in Pattern, inArm: in Bool): Unit {
  match pat.kind {
    case PBinding(name, inner) -> {
      val isCase = match inner {
        case None -> inArm and cx.caseSites.containsKey(recordCopySiteKey(pat.span))
        case Some(_) -> false
      }
      if not isCase {
        shadow(cx, shadowed, name)
      }
      match inner {
        case Some(p) -> shadowPattern(cx, shadowed, p, inArm)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      for a in args {
        shadowPattern(cx, shadowed, a, inArm)
      }
    }
    case PRecord(_, rfields, _) -> {
      for f in rfields {
        match f {
          case RPFNamed(_, p, _) -> shadowPattern(cx, shadowed, p, inArm)
          case RPFShort(name, _) -> shadow(cx, shadowed, name)
        }
      }
    }
    case PTuple(ps) -> {
      for p in ps {
        shadowPattern(cx, shadowed, p, inArm)
      }
    }
    case PParen(inner) -> shadowPattern(cx, shadowed, inner, inArm)
    case PTypeTest(inner, _) -> shadowPattern(cx, shadowed, inner, inArm)
    // Every alternative of an or-pattern binds the same names.
    case POr(ps) -> {
      for p in ps {
        shadowPattern(cx, shadowed, p, inArm)
      }
    }
    case _ -> ()
  }
}

/// The member names `params` hides.
func paramScope(cx: in Members, params: in List[Param]): Map[String, Bool] {
  val shadowed: Map[String, Bool] = newMap()
  for p in params {
    shadow(cx, shadowed, p.name)
  }
  shadowed
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. The rewrite.
// ─────────────────────────────────────────────────────────────────────────────
// `self.<name>` in place of the bare name spanning `sp`.  The member access
// keeps the name's span, so a side table the type checker keyed by that
// expression (an array index, `.length`, a conversion) still finds it; the
// implicit `self` gets an empty span at the name's start, which no such table
// keys, so it is never mistaken for the expression itself.
func selfField(name: in String, sp: in Span): Expr {
  val selfSpan = Span(startPos = sp.startPos, endPos = sp.startPos)
  Expr(kind = EMember(receiver = Expr(kind = ESelf, span = selfSpan), memberName = name), span = sp)
}

func rwExprs(cx: in Members, shadowed: in Map[String, Bool], es: in List[Expr]): List[Expr] {
  val acc: List[Expr] = newList()
  for e in es {
    acc.add(rwExpr(cx, shadowed, e))
  }
  acc
}

func rwArgs(cx: in Members, shadowed: in Map[String, Bool], args: in List[CallArg]): List[CallArg] {
  val acc: List[CallArg] = newList()
  for a in args {
    match a {
      case CAPositional(e) -> acc.add(CAPositional(expr = rwExpr(cx, shadowed, e)))
      // The label names the callee's parameter or field, never a value.
      case CANamed(name, v, sp) -> acc.add(CANamed(name = name, value = rwExpr(cx, shadowed, v), span = sp))
    }
  }
  acc
}

func rwEob(cx: in Members, shadowed: in Map[String, Bool], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBExpr(e) -> EOBExpr(expr = rwExpr(cx, shadowed, e))
    case EOBBlock(b) -> EOBBlock(block = rwBlock(cx, shadowed, b))
  }
}

func rwRange(cx: in Members, shadowed: in Map[String, Bool], b: in RangeBound): RangeBound {
  match b {
    case RBClosed(lo, hi) -> RBClosed(lo = rwExpr(cx, shadowed, lo), hi = rwExpr(cx, shadowed, hi))
    case RBHalfOpen(lo, hi, bare) -> RBHalfOpen(
      lo = rwExpr(cx, shadowed, lo),
      hi = rwExpr(cx, shadowed, hi),
      bareDotDot = bare
    )
    case RBLowerOpen(hi) -> RBLowerOpen(hi = rwExpr(cx, shadowed, hi))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = rwExpr(cx, shadowed, lo))
  }
}

func binderScope(cx: in Members, shadowed: in Map[String, Bool], binders: in List[PropertyBinder]): Map[String, Bool] {
  val inner = copyNames(shadowed)
  for b in binders {
    shadow(cx, inner, b.name)
  }
  inner
}

func rwOptExpr(cx: in Members, shadowed: in Map[String, Bool], e: in Option[Expr]): Option[Expr] {
  match e {
    case Some(x) -> Some(value = rwExpr(cx, shadowed, x))
    case None -> None
  }
}

func rwExpr(cx: in Members, shadowed: in Map[String, Bool], e: in Expr): Expr {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        if cx.fields.containsKey(name) and not shadowed.containsKey(name) {
          return selfField(name, e.span)
        }
      }
      e
    }
    case _ -> Expr(kind = rwKind(cx, shadowed, e), span = e.span)
  }
}

// Every expression form but a bare path, with its operands rewritten.
func rwKind(cx: in Members, shadowed: in Map[String, Bool], e: in Expr): ExprKind {
  match e.kind {
    case EInterpolated(segs) -> {
      val acc: List[InterpolatedSegment] = newList()
      for s in segs {
        match s {
          case ISExpr(x) -> acc.add(ISExpr(expr = rwExpr(cx, shadowed, x)))
          case other -> acc.add(other)
        }
      }
      EInterpolated(segments = acc)
    }
    case EParen(inner) -> EParen(inner = rwExpr(cx, shadowed, inner))
    case ETuple(xs) -> ETuple(exprs = rwExprs(cx, shadowed, xs))
    case EList(xs) -> EList(exprs = rwExprs(cx, shadowed, xs))
    case EIf(cond, thenB, elseB, thenForm) -> EIf(
      cond = rwExpr(cx, shadowed, cond),
      thenBranch = rwEob(cx, shadowed, thenB),
      elseBranch = match elseB {
        case Some(b) -> Some(value = rwEob(cx, shadowed, b))
        case None -> None
      },
      thenForm = thenForm
    )
    case EMatch(scrutinee, arms) -> {
      val acc: List[MatchArm] = newList()
      for arm in arms {
        val armScope = copyNames(shadowed)
        shadowPattern(cx, armScope, arm.pattern, true)
        acc.add(
          MatchArm(
            pattern = arm.pattern,
            guard = rwOptExpr(cx, armScope, arm.guard),
            body = rwEob(cx, armScope, arm.body),
            span = arm.span
          )
        )
      }
      EMatch(scrutinee = rwExpr(cx, shadowed, scrutinee), arms = acc)
    }
    case EAwait(inner) -> EAwait(inner = rwExpr(cx, shadowed, inner))
    case EYield(inner) -> EYield(inner = rwExpr(cx, shadowed, inner))
    case ESpawn(inner) -> ESpawn(inner = rwExpr(cx, shadowed, inner))
    case ETry(inner) -> ETry(inner = rwExpr(cx, shadowed, inner))
    case EOld(inner) -> EOld(inner = rwExpr(cx, shadowed, inner))
    case EForall(binders, whereE, body, bf) -> {
      val inner = binderScope(cx, shadowed, binders)
      EForall(binders = binders, whereExpr = rwOptExpr(cx, inner, whereE), body = rwExpr(cx, inner, body), bodyForm = bf)
    }
    case EExists(binders, whereE, body, bf) -> {
      val inner = binderScope(cx, shadowed, binders)
      EExists(binders = binders, whereExpr = rwOptExpr(cx, inner, whereE), body = rwExpr(cx, inner, body), bodyForm = bf)
    }
    case ELambda(lps, body) -> {
      val inner = copyNames(shadowed)
      for lp in lps {
        shadow(cx, inner, lp.name)
      }
      ELambda(lambdaParams = lps, body = rwBlock(cx, inner, body))
    }
    case ECall(fn, args) -> ECall(fn = rwCallee(cx, shadowed, fn), args = rwArgs(cx, shadowed, args))
    case ETypeApp(fn, targs) -> ETypeApp(fn = rwExpr(cx, shadowed, fn), args = targs)
    case EIndex(recv, idx) -> EIndex(receiver = rwExpr(cx, shadowed, recv), indices = rwExprs(cx, shadowed, idx))
    case EMember(recv, name) -> EMember(receiver = rwExpr(cx, shadowed, recv), memberName = name)
    case EPropagate(inner) -> EPropagate(inner = rwExpr(cx, shadowed, inner))
    case EPrefix(op, operand) -> EPrefix(op = op, operand = rwExpr(cx, shadowed, operand))
    case EBinop(op, lhs, rhs) -> EBinop(op = op, lhs = rwExpr(cx, shadowed, lhs), rhs = rwExpr(cx, shadowed, rhs))
    case ERange(b) -> ERange(bound = rwRange(cx, shadowed, b))
    case EAssign(target, op, value) -> EAssign(
      target = rwExpr(cx, shadowed, target),
      op = op,
      value = rwExpr(cx, shadowed, value)
    )
    case EBlock(b) -> EBlock(block = rwBlock(cx, shadowed, b))
    case EUnsafe(b) -> EUnsafe(block = rwBlock(cx, shadowed, b))
    case other -> other
  }
}

// A bare call of a sibling method is a call on `self`; any other callee is
// an ordinary expression (a function-typed field is read through `self`).
func rwCallee(cx: in Members, shadowed: in Map[String, Bool], fn: in Expr): Expr {
  match fn.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        if cx.methods.containsKey(name) and not cx.fields.containsKey(name) and not shadowed.containsKey(name) {
          return selfField(name, fn.span)
        }
      }
      rwExpr(cx, shadowed, fn)
    }
    case _ -> rwExpr(cx, shadowed, fn)
  }
}

func rwBlock(cx: in Members, outer: in Map[String, Bool], b: in Block): Block {
  val shadowed = copyNames(outer)
  val acc: List[Statement] = newList()
  for s in b.statements {
    acc.add(rwStmt(cx, shadowed, s))
  }
  Block(statements = acc, span = b.span)
}

/// Rewrites `s` under `shadowed` and records in `shadowed` the fields a
/// local binding it declares hides for the rest of the enclosing block.
func rwStmt(cx: in Members, shadowed: in Map[String, Bool], s: in Statement): Statement {
  val k: StatementKind = match s.kind {
    case SLocal(binding) -> match binding {
      // The initializer is evaluated before the binding is in scope.
      case LBVal(pat, ty, init) -> {
        val init2 = rwExpr(cx, shadowed, init)
        shadowPattern(cx, shadowed, pat, false)
        SLocal(binding = LBVal(pat = pat, ty = ty, init = init2))
      }
      case LBVar(name, ty, init) -> {
        val init2 = rwOptExpr(cx, shadowed, init)
        shadow(cx, shadowed, name)
        SLocal(binding = LBVar(name = name, ty = ty, init = init2))
      }
      case LBLet(name, ty, init) -> {
        val init2 = rwExpr(cx, shadowed, init)
        shadow(cx, shadowed, name)
        SLocal(binding = LBLet(name = name, ty = ty, init = init2))
      }
    }
    case SAssign(target, op, value) -> SAssign(
      target = rwExpr(cx, shadowed, target),
      op = op,
      value = rwExpr(cx, shadowed, value)
    )
    case SReturn(value) -> SReturn(value = rwOptExpr(cx, shadowed, value))
    case SThrow(x) -> SThrow(expr = rwExpr(cx, shadowed, x))
    case STry(body, catches, fin) -> {
      val cs: List[CatchClause] = newList()
      for c in catches {
        val cscope = copyNames(shadowed)
        match c.bindName {
          case Some(n) -> shadow(cx, cscope, n)
          case None -> ()
        }
        cs.add(CatchClause(typeName = c.typeName, bindName = c.bindName, body = rwBlock(cx, cscope, c.body), span = c.span))
      }
      STry(
        body = rwBlock(cx, shadowed, body),
        catches = cs,
        finally_ = match fin { case Some(f) -> Some(value = rwBlock(cx, shadowed, f)); case None -> None }
      )
    }
    case SDefer(body) -> SDefer(body = rwBlock(cx, shadowed, body))
    case SScope(binding, body) -> {
      val inner = copyNames(shadowed)
      match binding {
        case Some(n) -> shadow(cx, inner, n)
        case None -> ()
      }
      SScope(binding = binding, body = rwBlock(cx, inner, body))
    }
    case SFor(label, pat, iter, body) -> {
      val inner = copyNames(shadowed)
      shadowPattern(cx, inner, pat, false)
      SFor(label = label, pat = pat, iter = rwExpr(cx, shadowed, iter), body = rwBlock(cx, inner, body))
    }
    case SWhile(label, cond, body) -> SWhile(
      label = label,
      cond = rwExpr(cx, shadowed, cond),
      body = rwBlock(cx, shadowed, body)
    )
    case SLoop(label, body) -> SLoop(label = label, body = rwBlock(cx, shadowed, body))
    case SInvariant(x) -> SInvariant(expr = rwExpr(cx, shadowed, x))
    case SExpr(x) -> SExpr(expr = rwExpr(cx, shadowed, x))
    case SRule(lhs, rhs) -> SRule(
      lhs = rwExpr(cx, shadowed, lhs),
      rhs = rwExpr(cx, shadowed, rhs)
    )
    // A nested declaration is its own scope, with no implicit receiver.
    case other -> other
  }
  Statement(kind = k, span = s.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Entry points.
// ─────────────────────────────────────────────────────────────────────────────
/// `e`, a contract clause of a member with `params` whose type has
/// `fields`, with each bare field reference written `self.<name>`.
/// `caseSites` are the bare `match`-arm patterns the type checker resolved
/// as cases (`SymbolTable.casePatternSites`).
pub func resolveSelfFieldsInExpr(
  fields: in Map[String, Bool],
  caseSites: in Map[String, Bool],
  params: in List[Param],
  e: in Expr,
): Expr {
  if fields.count == 0 {
    return e
  }
  val noMethods: Map[String, Bool] = newMap()
  val cx = Members(fields = fields, methods = noMethods, caseSites = caseSites)
  rwExpr(cx, paramScope(cx, params), e)
}

/// `body`, of a member with `params` whose type has `fields`, with each bare
/// reference that resolves to a field written `self.<name>`, and each bare
/// call of one of `methods` — the type's sibling members, for a backend that
/// lowers such a call as a call on `self` — written as one.  `caseSites`
/// are the bare `match`-arm patterns the type checker resolved as cases
/// (`SymbolTable.casePatternSites`).
pub func resolveSelfMembersInBody(
  fields: in Map[String, Bool],
  methods: in Map[String, Bool],
  caseSites: in Map[String, Bool],
  params: in List[Param],
  body: in FunctionBody,
): FunctionBody {
  if fields.count == 0 and methods.count == 0 {
    return body
  }
  val cx = Members(fields = fields, methods = methods, caseSites = caseSites)
  val shadowed = paramScope(cx, params)
  match body {
    case FBExpr(e) -> FBExpr(expr = rwExpr(cx, shadowed, e))
    case FBBlock(b) -> FBBlock(block = rwBlock(cx, shadowed, b))
  }
}

/// True when `anns` marks a member body this package already resolved
/// (an inherited interface default is marked too).  Its bare names are not
/// fields and must not be resolved again: a later pass may have added code
/// (an inherited contract clause) whose bare names belong to the interface's
/// scope.
pub func isSelfResolved(anns: in List[Annotation]): Bool {
  hasMarkerAnnotation(anns, selfResolvedAnnotationName())
}

/// True when `anns` marks an inherited interface default
/// (`Lyric.ImplDefaults`), whose body sees none of the target's fields.
pub func isInheritedDefault(anns: in List[Annotation]): Bool {
  hasMarkerAnnotation(anns, inheritedDefaultAnnotationName())
}

/// `body`, of a member annotated `anns` with `params` whose type has
/// `fields`, resolved as `resolveSelfMembersInBody` resolves it (with
/// `methods` the sibling members whose bare calls the caller lowers as
/// calls on `self`), unless the middle end already resolved it or it is an
/// inherited interface default: then only `methods` are resolved.  For a
/// backend lowering a member that may come from a file the middle end did
/// not process.
pub func resolveUnmarkedBody(
  fields: in Map[String, Bool],
  methods: in Map[String, Bool],
  anns: in List[Annotation],
  params: in List[Param],
  body: in FunctionBody,
): FunctionBody {
  val noCases: Map[String, Bool] = newMap()
  if isSelfResolved(anns) or isInheritedDefault(anns) {
    val noFields: Map[String, Bool] = newMap()
    return resolveSelfMembersInBody(noFields, methods, noCases, params, body)
  }
  resolveSelfMembersInBody(fields, methods, noCases, params, body)
}

/// `fn`, a member of a type with `fields`, with its body resolved as
/// `resolveUnmarkedBody` resolves it (no sibling calls).
pub func resolveUnmarkedFunc(fields: in Map[String, Bool], fn: in FunctionDecl): FunctionDecl {
  val noMethods: Map[String, Bool] = newMap()
  match fn.body {
    case Some(b) -> fn.copy(body = Some(value = resolveUnmarkedBody(fields, noMethods, fn.annotations, fn.params, b)))
    case None -> fn
  }
}

func resolvedMark(anns: in List[Annotation], sp: in Span): List[Annotation] {
  withMarkerAnnotation(anns, selfResolvedAnnotationName(), sp)
}

/// `fn`, a member of a type with `fields`: its body resolved and the member
/// marked resolved.  An inherited interface default is only marked; one
/// already marked is returned unchanged.
func resolveMemberFn(fields: in Map[String, Bool], caseSites: in Map[String, Bool], fn: in FunctionDecl): FunctionDecl {
  if isSelfResolved(fn.annotations) {
    return fn
  }
  if isInheritedDefault(fn.annotations) {
    return fn.copy(annotations = resolvedMark(fn.annotations, fn.span))
  }
  val noMethods: Map[String, Bool] = newMap()
  match fn.body {
    case Some(b) -> fn.copy(
      body = Some(value = resolveSelfMembersInBody(fields, noMethods, caseSites, fn.params, b)),
      annotations = resolvedMark(fn.annotations, fn.span)
    )
    case None -> fn
  }
}

func resolveMemberEntry(fields: in Map[String, Bool], caseSites: in Map[String, Bool], ed: in EntryDecl): EntryDecl {
  if isSelfResolved(ed.annotations) {
    return ed
  }
  if isInheritedDefault(ed.annotations) {
    return ed.copy(annotations = resolvedMark(ed.annotations, ed.span))
  }
  val noMethods: Map[String, Bool] = newMap()
  ed.copy(
    body = resolveSelfMembersInBody(fields, noMethods, caseSites, ed.params, ed.body),
    annotations = resolvedMark(ed.annotations, ed.span)
  )
}

func resolveProtected(caseSites: in Map[String, Bool], decl: in ProtectedTypeDecl): ProtectedTypeDecl {
  val fields = protectedFieldNames(decl.members)
  val acc: List[ProtectedMember] = newList()
  for m in decl.members {
    match m {
      case PMEntry(ed) -> acc.add(PMEntry(entryDecl = resolveMemberEntry(fields, caseSites, ed)))
      case PMFunc(fn) -> acc.add(PMFunc(fn = resolveMemberFn(fields, caseSites, fn)))
      case other -> acc.add(other)
    }
  }
  decl.copy(members = acc)
}

func resolveRecord(caseSites: in Map[String, Bool], decl: in RecordDecl): RecordDecl {
  val fields = recordFieldNames(decl.members)
  val acc: List[RecordMember] = newList()
  for m in decl.members {
    match m {
      case RMFunc(fn) -> acc.add(RMFunc(fn = resolveMemberFn(fields, caseSites, fn)))
      case other -> acc.add(other)
    }
  }
  decl.copy(members = acc)
}

func resolveImpl(index: in Map[String, Map[String, Bool]], caseSites: in Map[String, Bool], decl: in ImplDecl): ImplDecl {
  // A target the index does not hold keeps its bodies, unmarked: codegen
  // resolves their bare field names itself.  An inherited default is marked
  // either way, since no field is in its scope.
  val fields = implTargetFieldNames(index, decl.target)
  val acc: List[ImplMember] = newList()
  for m in decl.members {
    match m {
      case IMplFunc(fn) -> {
        if fields.count > 0 or isInheritedDefault(fn.annotations) {
          acc.add(IMplFunc(fn = resolveMemberFn(fields, caseSites, fn)))
        } else {
          acc.add(m)
        }
      }
      case other -> acc.add(other)
    }
  }
  decl.copy(members = acc)
}

/// `file` with every bare field reference in a protected member, a
/// record-body method and an `impl` method written `self.<name>`, under the
/// type checker's scoping, and each such member marked resolved
/// (`selfResolvedAnnotationName`).  `extraRecords` supplies the fields of an
/// `impl` target declared outside `file`; `caseSites` the bare `match`-arm
/// patterns the type checker resolved as cases
/// (`SymbolTable.casePatternSites`; empty for a file it did not check, where
/// every bare pattern binds).  A member already marked is left as it is, so
/// applying it twice is applying it once.
pub func resolveSelfFieldsInFile(
  file: in SourceFile, extraRecords: in List[RecordDecl], caseSites: in Map[String, Bool]
): SourceFile {
  val index = typeFieldIndex(file, extraRecords)
  val items: List[Item] = newList()
  for it in file.items {
    val k: ItemKind = match it.kind {
      case IProtected(decl) -> IProtected(decl = resolveProtected(caseSites, decl))
      case IRecord(decl) -> IRecord(decl = resolveRecord(caseSites, decl))
      case IExposedRec(decl) -> IExposedRec(decl = resolveRecord(caseSites, decl))
      case IImpl(decl) -> IImpl(decl = resolveImpl(index, caseSites, decl))
      case other -> other
    }
    items.add(it.copy(kind = k))
  }
  file.copy(items = items)
}
