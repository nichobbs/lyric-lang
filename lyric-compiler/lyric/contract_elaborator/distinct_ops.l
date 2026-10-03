//! Operators on distinct types are lowered through the underlying value
//! (#7361).
//!
//! A distinct type (`type UserId = Long`, `type Cents = Long range 0 ..= 1000
//! derives Add, Sub, Compare`) is a wrapper class with a `value` field on the
//! managed targets, and the checker accepts `==`, `!=` and the derived
//! operators on it.  No backend lowered those through the wrapper: arithmetic
//! operated on object references (memory corruption on dotnet, a verify
//! error on the JVM) and `==` compared references.  The checker records
//! every such operator (`SymbolTable.distinctOpSites` /
//! `distinctCompoundSites`) and this pass rewrites it:
//!
//! - `a op b` (derived arithmetic) becomes `T.from(a.value op b.value)`,
//!   which also re-checks a range subtype's bounds (#7226);
//! - `a == b`, `a != b` and derived comparisons become `a.value op b.value`;
//! - `x op= y` becomes `x = T.from(x.value op y.value)`.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

pub func lowerDistinctOps(
  file: in SourceFile, opSites: in Map[String, String], compoundSites: in Map[String, String]
): SourceFile {
  if opSites.count == 0 and compoundSites.count == 0 {
    return file
  }
  mapFileAndContracts(
    file,
    { e: Expr -> rewriteDistinctBinop(e, opSites) },
    { s: Statement -> rewriteDistinctCompound(s, compoundSites) }
  )
}

// A zero-width span at `sp`'s start: a synthesized node must not share a
// recorded site's key.
func syntheticSpan(sp: in Span): Span {
  Span(startPos = sp.startPos, endPos = sp.startPos)
}

func valueOf(e: in Expr): Expr {
  val sp = syntheticSpan(e.span)
  mkExpr(EMember(receiver = e, memberName = "value"), sp)
}

// `T.from(arg)`, spelled as the parser spells a static member call: a member
// access on the type's path (`EMember(EPath([T]), "from")`), which is the
// shape every backend resolves.
func fromCall(path: in String, arg: in Expr, sp: in Span): Expr {
  val parts = Str.split(path, ".")
  val segs: List[String] = newList()
  var i = 0
  while i < parts.length - 1 {
    segs.add(parts[i])
    i = i + 1
  }
  val wsp = syntheticSpan(sp)
  val typePath = mkExpr(EPath(path = ModulePath(segments = segs, span = wsp)), wsp)
  val callee = mkExpr(EMember(receiver = typePath, memberName = parts[parts.length - 1]), wsp)
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = arg))
  mkExpr(ECall(fn = callee, args = args), wsp)
}

func rewriteDistinctBinop(e: in Expr, sites: in Map[String, String]): Expr {
  match e.kind {
    case EBinop(op, lhs, rhs) -> match mapGet(sites, recordCopySiteKey(e.span)) {
      case Some(kind) -> {
        val onValues = mkExpr(EBinop(op = op, lhs = valueOf(lhs), rhs = valueOf(rhs)), syntheticSpan(e.span))
        if Str.startsWith(kind, "arith:") {
          fromCall(Str.substring(kind, 6, kind.length - 6), onValues, e.span)
        } else {
          onValues
        }
      }
      case None -> e
    }
    case _ -> e
  }
}

func compoundBinOp(op: in AssignOp): Option[BinOp] {
  match op {
    case AssPlus -> Some(value = BAdd)
    case AssMinus -> Some(value = BSub)
    case AssStar -> Some(value = BMul)
    case AssSlash -> Some(value = BDiv)
    case AssPercent -> Some(value = BMod)
    case AssEq -> None
  }
}

// `t op= v`  ->  `t = T.from(t.value op v.value)`.  The type checker only
// records a compound site whose target is a variable or field path (T0134
// otherwise), so evaluating `t` twice is side-effect free.
func rewriteDistinctCompound(s: in Statement, sites: in Map[String, String]): Statement {
  match s.kind {
    case SAssign(target, op, value) -> match mapGet(sites, recordCopySiteKey(s.span)) {
      case Some(path) -> match compoundBinOp(op) {
        case Some(bop) -> {
          val wsp = syntheticSpan(s.span)
          val combined = mkExpr(EBinop(op = bop, lhs = valueOf(target), rhs = valueOf(value)), wsp)
          mkStmt(SAssign(target = target, op = AssEq, value = fromCall(path, combined, s.span)), s.span)
        }
        case None -> s
      }
      case None -> s
    }
    case _ -> s
  }
}

// Derived component-wise arithmetic on a homogeneous numeric record (D155):
//
//   a + b   ->   {
//                  val __lyric_ra_<s>_<e>_l: R = a
//                  val __lyric_ra_<s>_<e>_r: R = b
//                  R(x = <l>.x + <r>.x, y = <l>.y + <r>.y, ...)
//                }
//
// so each operand is evaluated once, left to right, and `r += s` becomes
// `r = <the same block>` (the checker allows only a variable or field target
// there).  The temporaries are typed so a backend that erases an unannotated
// local (the JVM) can read the fields back.
pub func lowerRecordArith(file: in SourceFile, sites: in Map[String, RecordArithSite]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapFileAndContracts(
    file,
    { e: Expr -> rewriteRecordBinop(e, sites) },
    { s: Statement -> rewriteRecordCompound(s, sites) }
  )
}

func rewriteRecordBinop(e: in Expr, sites: in Map[String, RecordArithSite]): Expr {
  match e.kind {
    case EBinop(_, lhs, rhs) -> match mapGet(sites, recordCopySiteKey(e.span)) {
      case Some(site) -> recordArithBlock(site, lhs, rhs, e.span)
      case None -> e
    }
    case _ -> e
  }
}

func rewriteRecordCompound(s: in Statement, sites: in Map[String, RecordArithSite]): Statement {
  match s.kind {
    case SAssign(target, op, value) -> match op {
      case AssEq -> s
      case _ -> match mapGet(sites, recordCopySiteKey(s.span)) {
        case Some(site) -> mkStmt(
          SAssign(
            target = target,
            op = AssEq,
            value = recordArithBlock(
              site,
              target,
              value,
              s.span
            )
          ),
          s.span
        )
        case None -> s
      }
    }
    case _ -> s
  }
}

func recordArithBlock(site: in RecordArithSite, lhs: in Expr, rhs: in Expr, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_ra_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
  val lName = base + "_l"
  val rName = base + "_r"
  val stmts: List[Statement] = newList()
  stmts.add(typedVal(lName, site.recordType, lhs, wsp))
  stmts.add(typedVal(rName, site.recordType, rhs, wsp))
  val args: List[CallArg] = newList()
  for f in site.fields {
    val lf = mkExpr(EMember(receiver = localPath(lName, wsp), memberName = f), wsp)
    val rf = mkExpr(EMember(receiver = localPath(rName, wsp), memberName = f), wsp)
    args.add(CANamed(name = f, value = mkExpr(EBinop(op = site.op, lhs = lf, rhs = rf), wsp), span = wsp))
  }
  val parts = Str.split(site.recordName, ".")
  val segs: List[String] = newList()
  var i = 0
  while i < parts.length {
    segs.add(parts[i])
    i = i + 1
  }
  val ctor = mkExpr(ECall(fn = mkExpr(EPath(path = ModulePath(segments = segs, span = wsp)), wsp), args = args), wsp)
  stmts.add(mkStmt(SExpr(expr = ctor), wsp))
  mkExpr(EBlock(block = Block(statements = stmts, span = wsp)), wsp)
}

/// Lower `==` / `!=` on a structural record (D164) into a block that binds
/// each operand once, left to right, and compares the two field by field:
/// `{ val l: T = a; val r: T = b; l.f == r.f and l.g.h == r.g.h }`, negated
/// for `!=`.  A record with no fields compares equal.
pub func lowerRecordEq(
  file: in SourceFile,
  sites: in Map[String, RecordEqSite],
  arraySites: in Map[String, ArrayEqSite],
  wrapSites: in Map[String, WrapEqSite],
): SourceFile {
  if sites.count == 0 and arraySites.count == 0 and wrapSites.count == 0 {
    return file
  }
  mapFileAndContracts(file, { e: Expr -> rewriteRecordEq(e, sites, arraySites, wrapSites) }, { s: Statement -> s })
}

func rewriteRecordEq(
  e: in Expr,
  sites: in Map[String, RecordEqSite],
  arraySites: in Map[String, ArrayEqSite],
  wrapSites: in Map[String, WrapEqSite],
): Expr {
  match e.kind {
    case EBinop(_, lhs, rhs) -> {
      val key = recordCopySiteKey(e.span)
      match mapGet(sites, key) {
        case Some(site) -> recordEqBlock(site, lhs, rhs, e.span, "")
        case None -> match mapGet(arraySites, key) {
          case Some(site) -> arrayEqBlock(site, lhs, rhs, e.span, "")
          case None -> match mapGet(wrapSites, key) {
            case Some(site) -> wrapEqBlock(site, lhs, rhs, e.span)
            case None -> e
          }
        }
      }
    }
    case _ -> e
  }
}

// `a == b` on a tuple, union or distinct type holding an array (D167): each
// operand is bound once, then compared part by part, an array element by
// element.
//   { val l: T = a
//     val r: T = b
//     match l { case C(x0) -> match r { case C(y0) -> <x0 == y0>; case _ -> false }; ... } }
func wrapEqBlock(site: in WrapEqSite, lhs: in Expr, rhs: in Expr, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_weq_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
  val lName = base + "_l"
  val rName = base + "_r"
  val stmts: List[Statement] = newList()
  stmts.add(typedVal(lName, site.valueType, lhs, wsp))
  stmts.add(typedVal(rName, site.valueType, rhs, wsp))
  val cmp = eqShapeExpr(site.shape, localPath(lName, wsp), localPath(rName, wsp), sp, "w")
  val result = if site.negate {
    mkExpr(EPrefix(op = PreNot, operand = mkExpr(EParen(inner = cmp), wsp)), wsp)
  } else {
    cmp
  }
  stmts.add(mkStmt(SExpr(expr = result), wsp))
  mkExpr(EBlock(block = Block(statements = stmts, span = wsp)), wsp)
}

func boolLit(b: in Bool, sp: in Span): Expr {
  mkExpr(ELiteral(lit = LBool(value = b)), sp)
}

func matchArm(pat: in Pattern, body: in Expr, sp: in Span): MatchArm {
  MatchArm(pattern = pat, guard = None, body = EOBExpr(expr = body), span = sp)
}

func bindingPat(name: in String, sp: in Span): Pattern {
  Pattern(kind = PBinding(name = name, inner = None), span = sp)
}

// The names `<tag><prefix><k>` for `k` in `0 ..< n`, and the patterns that bind them.
func shapeNames(base: in String, n: in Int): List[String] {
  val names: List[String] = newList()
  var k = 0
  while k < n {
    names.add(base + toString(k))
    k = k + 1
  }
  names
}

func bindingPats(names: in List[String], sp: in Span): List[Pattern] {
  val ps: List[Pattern] = newList()
  for nm in names {
    ps.add(bindingPat(nm, sp))
  }
  ps
}

// The conjunction of each part's comparison (`true` for none).
func partsEq(shapes: in List[EqShape], xs: in List[String], ys: in List[String], sp: in Span, tag: in String): Expr {
  val wsp = syntheticSpan(sp)
  var cmp = boolLit(true, wsp)
  var k = 0
  while k < shapes.count {
    val part = eqShapeExpr(shapes[k], localPath(xs[k], wsp), localPath(ys[k], wsp), sp, tag + "p" + toString(k) + "_")
    cmp = if k == 0 { part } else { mkExpr(EBinop(op = BAnd, lhs = cmp, rhs = part), wsp) }
    k = k + 1
  }
  cmp
}

func eqShapeExpr(shape: in EqShape, a: in Expr, b: in Expr, sp: in Span, tag: in String): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_ws_" + tag + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
  match shape {
    case ESPlain -> mkExpr(EBinop(op = BEq, lhs = a, rhs = b), wsp)
    case ESArray(site) -> arrayEqBlock(site, a, b, sp, tag)
    case ESRecord(site) -> recordEqBlock(site, a, b, sp, tag)
    case ESDistinct(inner) -> eqShapeExpr(inner, valueOf(a), valueOf(b), sp, tag + "d")
    case ESTuple(elems) -> {
      val xs = shapeNames(base + "_x", elems.count)
      val ys = shapeNames(base + "_y", elems.count)
      val inner = partsEq(elems, xs, ys, sp, tag)
      val matchB = mkExpr(
        EMatch(
          scrutinee = b,
          arms = oneArm(
            matchArm(Pattern(kind = PTuple(patterns = bindingPats(ys, wsp)), span = wsp), inner, wsp)
          )
        ),
        wsp
      )
      mkExpr(
        EMatch(
          scrutinee = a,
          arms = oneArm(matchArm(Pattern(kind = PTuple(patterns = bindingPats(xs, wsp)), span = wsp), matchB, wsp))
        ),
        wsp
      )
    }
    case ESUnion(cases) -> {
      val armsA: List[MatchArm] = newList()
      var ci = 0
      for c in cases {
        val xs = shapeNames(base + "_c" + toString(ci) + "x", c.fields.count)
        val ys = shapeNames(base + "_c" + toString(ci) + "y", c.fields.count)
        val headPath = ModulePath(segments = c.head, span = wsp)
        val inner = partsEq(c.fields, xs, ys, sp, tag + "c" + toString(ci) + "_")
        val armsB: List[MatchArm] = newList()
        armsB.add(
          matchArm(Pattern(kind = PConstructor(head = headPath, args = bindingPats(ys, wsp)), span = wsp), inner, wsp)
        )
        armsB.add(matchArm(Pattern(kind = PWildcard, span = wsp), boolLit(false, wsp), wsp))
        val matchB = mkExpr(EMatch(scrutinee = b, arms = armsB), wsp)
        armsA.add(
          matchArm(Pattern(kind = PConstructor(head = headPath, args = bindingPats(xs, wsp)), span = wsp), matchB, wsp)
        )
        ci = ci + 1
      }
      mkExpr(EMatch(scrutinee = a, arms = armsA), wsp)
    }
  }
}

func oneArm(arm: in MatchArm): List[MatchArm] {
  val arms: List[MatchArm] = newList()
  arms.add(arm)
  arms
}

func recordEqBlock(site: in RecordEqSite, lhs: in Expr, rhs: in Expr, sp: in Span, tag: in String): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_req_" + tag + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
  val lName = base + "_l"
  val rName = base + "_r"
  val stmts: List[Statement] = newList()
  stmts.add(typedVal(lName, site.recordType, lhs, wsp))
  stmts.add(typedVal(rName, site.recordType, rhs, wsp))
  // Each nested record level is bound once per side to a temporary of its
  // type: a backend that erases generic fields cannot read a member off an
  // untyped intermediate value.
  val lLevels: Map[String, String] = newMap()
  val rLevels: Map[String, String] = newMap()
  var cmp = mkExpr(ELiteral(lit = LBool(value = true)), wsp)
  var first = true
  var leafNo = 0
  for path in site.paths {
    val lhsLeaf = leafRead(lName, path, site.levelTypes, lLevels, stmts, wsp)
    val rhsLeaf = leafRead(rName, path, site.levelTypes, rLevels, stmts, wsp)
    val leaf = match mapGet(site.arrayLeaves, dottedLeaf(path)) {
      case Some(arr) -> arrayEqBlock(arr, lhsLeaf, rhsLeaf, sp, tag + "f" + toString(leafNo) + "_")
      case None -> match mapGet(site.wrapLeaves, dottedLeaf(path)) {
        case Some(sh) -> eqShapeExpr(sh, lhsLeaf, rhsLeaf, sp, tag + "f" + toString(leafNo) + "_")
        case None -> mkExpr(EBinop(op = BEq, lhs = lhsLeaf, rhs = rhsLeaf), wsp)
      }
    }
    cmp = if first { leaf } else { mkExpr(EBinop(op = BAnd, lhs = cmp, rhs = leaf), wsp) }
    first = false
    leafNo = leafNo + 1
  }
  val result = if site.negate {
    mkExpr(EPrefix(op = PreNot, operand = mkExpr(EParen(inner = cmp), wsp)), wsp)
  } else {
    cmp
  }
  stmts.add(mkStmt(SExpr(expr = result), wsp))
  mkExpr(EBlock(block = Block(statements = stmts, span = wsp)), wsp)
}

func dottedLeaf(path: in List[String]): String {
  var joined = ""
  for seg in path {
    joined = if joined.length == 0 { seg } else { joined + "." + seg }
  }
  joined
}

// `a == b` on two arrays (D167): each operand is bound once, then compared
// element by element, an element that is a structural record field by field
// and a nested array in turn.
//   { val l: array[N, T] = a
//     val r: array[N, T] = b
//     var i = 0
//     var ok = true
//     while ok and i < N { if not (l[i] == r[i]) { ok = false }; i = i + 1 }
//     ok }
func arrayEqBlock(site: in ArrayEqSite, lhs: in Expr, rhs: in Expr, sp: in Span, tag: in String): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_aeq_" + tag + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
  val lName = base + "_l"
  val rName = base + "_r"
  val iName = base + "_i"
  val okName = base + "_ok"
  val stmts: List[Statement] = newList()
  stmts.add(typedVal(lName, site.arrayType, lhs, wsp))
  stmts.add(typedVal(rName, site.arrayType, rhs, wsp))
  stmts.add(
    mkStmt(
      SLocal(binding = LBVar(name = iName, ty = Some(value = intTypeExpr(wsp)), init = Some(value = intLit(0, wsp)))),
      wsp
    )
  )
  stmts.add(
    mkStmt(
      SLocal(
        binding = LBVar(
          name = okName,
          ty = Some(value = boolTypeExpr(wsp)),
          init = Some(value = mkExpr(ELiteral(lit = LBool(value = true)), wsp))
        )
      ),
      wsp
    )
  )
  val le = uncheckedIndex(localRef(lName, wsp), localRef(iName, wsp), wsp)
  val re = uncheckedIndex(localRef(rName, wsp), localRef(iName, wsp), wsp)
  val same: Expr = match site.elem {
    case AEPlain -> mkExpr(EBinop(op = BEq, lhs = le, rhs = re), wsp)
    case AEValue -> mkExpr(EBinop(op = BEq, lhs = valueOf(le), rhs = valueOf(re)), wsp)
    case AERecord(rs) -> recordEqBlock(rs, le, re, sp, tag + "e_")
    case AEArray(inner) -> arrayEqBlock(inner, le, re, sp, tag + "e_")
    case AEShape(sh) -> eqShapeExpr(sh, le, re, sp, tag + "e_")
  }
  val setFalse: List[Statement] = newList()
  setFalse.add(
    mkStmt(
      SAssign(target = localRef(okName, wsp), op = AssEq, value = mkExpr(ELiteral(lit = LBool(value = false)), wsp)),
      wsp
    )
  )
  val notSame = mkExpr(EPrefix(op = PreNot, operand = mkExpr(EParen(inner = same), wsp)), wsp)
  val ifE = mkExpr(
    EIf(
      cond = notSame,
      thenBranch = EOBBlock(block = Block(statements = setFalse, span = wsp)),
      elseBranch = None,
      thenForm = false
    ),
    wsp
  )
  val body: List[Statement] = newList()
  body.add(mkStmt(SExpr(expr = ifE), wsp))
  body.add(incrementStmt(iName, wsp))
  val cond = bin(BAnd, localRef(okName, wsp), bin(BLt, localRef(iName, wsp), intLit(site.len, wsp), wsp), wsp)
  stmts.add(mkStmt(SWhile(label = None, cond = cond, body = Block(statements = body, span = wsp)), wsp))
  val ok = localRef(okName, wsp)
  val result = if site.negate { mkExpr(EPrefix(op = PreNot, operand = ok), wsp) } else { ok }
  stmts.add(mkStmt(SExpr(expr = result), wsp))
  mkExpr(EBlock(block = Block(statements = stmts, span = wsp)), wsp)
}

// The read of the leaf at `path` off operand `local`, binding each nested
// record level `levelTypes` names to a typed temporary the first time a path
// goes through it (`levels` maps a level's dotted path to its temporary).
func leafRead(
  local: in String,
  path: in List[String],
  levelTypes: in Map[String, TypeExpr],
  levels: in Map[String, String],
  stmts: in List[Statement],
  sp: in Span,
): Expr {
  var e = localPath(local, sp)
  var dotted = ""
  var i = 0
  while i < path.count {
    val seg = path[i]
    dotted = if dotted.length == 0 { seg } else { dotted + "." + seg }
    e = mkExpr(EMember(receiver = e, memberName = seg), sp)
    if i < path.count - 1 {
      match mapGet(levels, dotted) {
        case Some(bound) -> {
          e = localPath(bound, sp)
        }
        case None -> match mapGet(levelTypes, dotted) {
          case Some(te) -> {
            val name = local + "_" + toString(levels.count)
            stmts.add(typedVal(name, Some(value = te), e, sp))
            levels[dotted] = name
            e = localPath(name, sp)
          }
          case None -> ()
        }
      }
    }
    i = i + 1
  }
  e
}

func typedVal(name: in String, ty: in Option[TypeExpr], init: in Expr, sp: in Span): Statement {
  val pat = Pattern(kind = PBinding(name = name, inner = None), span = sp)
  mkStmt(SLocal(binding = LBVal(pat = pat, ty = ty, init = init)), sp)
}

func localPath(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
}
