//! derives.l — Lyric.Derives
//!
//! AST-to-AST synthesiser for `@derive(Equals)`, `@derive(Hash)`,
//! `@derive(Show)`, and `@generate(Json)` on records and distinct types.
//! Mirrors the F# synthesis in `bootstrap/src/Lyric.Parser/JsonDerive.fs`
//! and inline derive emission in `bootstrap/src/Lyric.Emitter/Emitter.fs`.
//!
//! The synthesiser appends `IFunc` items to the file's items list for each
//! annotated type.  Both MSIL and JVM bridges call this pass after the
//! contract elaborator and before codegen.
//!
//! Scope (docs/41 §9 Band 5 — #857):
//!
//!   Records / exposed records:
//!   - @derive(Equals)  → `TypeName.equals(self, other): Bool`
//!   - @derive(Hash)    → `TypeName.hash(self): Int`
//!   - @derive(Show)    → `TypeName.show(self): String`
//!   - @generate(Json)  → `TypeName.toJson(self): String`
//!
//!   Distinct types (via `derives` list on DistinctTypeDecl):
//!   - derives Equals   → `TypeName.equals(self, other): Bool`
//!   - derives Hash     → `TypeName.hash(self): Int`
//!   - derives Show     → `TypeName.show(self): String`
//!
//!   Unions:
//!   - @derive(Equals)  → `TypeName.equals(self, other): Bool`
//!   - @derive(Hash)    → `TypeName.hash(self): Int`
//!   - @derive(Show)    → `TypeName.show(self): String`
//!   - @derive(Ord)     → `TypeName.compare(self, other): Int`
//!
//!   Enums:
//!   - @derive(Equals)  → `TypeName.equals(self, other): Bool`
//!   - @derive(Hash)    → `TypeName.hash(self): Int`
//!   - @derive(Show)    → `TypeName.show(self): String`
//!   - @derive(Ord)     → `TypeName.compare(self, other): Int`
//!
//!   @derive(Ord) on records/distinct types:
//!   - @derive(Ord)     → `TypeName.compare(self, other): Int`
//!
//! Public surface:
//!
//!   pub func deriveFile(file: in SourceFile): SourceFile
//!
package Lyric.Derives

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Annotation predicates.
// ─────────────────────────────────────────────────────────────────────────────
// Returns the single bare-name arg of `@outer(Name)` if present; None otherwise.
func annotationArg1(ann: in Annotation, outer: in String): Option[String] {
  if ann.name.segments.count == 1 and ann.name.segments[0] == outer {
    if ann.args.count > 0 {
      match ann.args[0] {
        case ABare(nm, _) -> {
          return Some(nm)
        }
        case ALiteral(value, _) -> {
          match value {
            case AVIdent(nm, _) -> {
              return Some(nm)
            }
            case _ -> {
              return None
            }
          }
        }
        case AAName(_, _, _) -> {
          return None
        }
      }
    }
  }
  None
}

func hasDeriveMarker(anns: in List[Annotation], marker: in String): Bool {
  var i = 0
  while i < anns.count {
    match annotationArg1(anns[i], "derive") {
      case Some(nm) -> {
        if nm == marker {
          return true
        }
      }
      case None -> ()
    }
    i = i + 1
  }
  false
}

func hasGenerateMarker(anns: in List[Annotation], marker: in String): Bool {
  var i = 0
  while i < anns.count {
    match annotationArg1(anns[i], "generate") {
      case Some(nm) -> {
        if nm == marker {
          return true
        }
      }
      case None -> ()
    }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. AST builder helpers.
// ─────────────────────────────────────────────────────────────────────────────
func sp(): Span {
  syntheticSpan()
}

func pathExpr(name: in String): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp())), sp())
}

func memberOf(recv: in Expr, memberName: in String): Expr {
  mkExpr(EMember(receiver = recv, memberName = memberName), sp())
}

func call1(fn: in String, arg: in Expr): Expr {
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = arg))
  mkExpr(ECall(fn = pathExpr(fn), args = args), sp())
}

// `recv.methodName(a1, a2)` — used to chain `String.replace` calls when
// JSON-escaping String field values inside synthesised `toJson` bodies.
func methodCall2(recv: in Expr, methodName: in String, a1: in Expr, a2: in Expr): Expr {
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = a1))
  args.add(CAPositional(expr = a2))
  val callee = mkExpr(EMember(receiver = recv, memberName = methodName), sp())
  mkExpr(ECall(fn = callee, args = args), sp())
}

func binop(op: in BinOp, lhs: in Expr, rhs: in Expr): Expr {
  mkExpr(EBinop(op = op, lhs = lhs, rhs = rhs), sp())
}

func strLit(s: in String): Expr {
  mkExpr(ELiteral(lit = LString(text = s)), sp())
}

func longLitOf(n: in Long): Expr {
  mkExpr(ELiteral(lit = LInt(value = n, suffix = NoIntSuffix, raw = "")), sp())
}

func stmtLocal(name: in String, ty: in Option[TypeExpr], initExpr: in Expr): Statement {
  mkStmt(SLocal(binding = LBVar(name = name, ty = ty, init = Some(initExpr))), sp())
}

func stmtAssign(target: in Expr, value: in Expr): Statement {
  mkStmt(SAssign(target = target, op = AssEq, value = value), sp())
}

func stmtReturn(value: in Expr): Statement {
  mkStmt(SReturn(value = Some(value)), sp())
}

func typeRef(name: in String): TypeExpr {
  val segs: List[String] = newList()
  segs.add(name)
  mkType(TRef(path = ModulePath(segments = segs, span = sp())), sp())
}

func blockReturn(expr: in Expr): Block {
  val stmts: List[Statement] = newList()
  stmts.add(stmtReturn(expr))
  Block(statements = stmts, span = sp())
}

func blockStmtsReturn(stmts: in List[Statement], trailing: in Expr): Block {
  stmts.add(stmtReturn(trailing))
  Block(statements = stmts, span = sp())
}

func emptyList[A](): List[A] {
  newList()
}

func makeParam(nm: in String, ty: in TypeExpr): Param {
  val noAnns: List[Annotation] = newList()
  // modeExplicit = false: synthesised params have no explicit mode keyword in
  // source — `in` is the default sugar, not an authored annotation.
  Param(mode = PMIn, modeExplicit = false, name = nm, ty = ty, dflt = None, annotations = noAnns, span = sp())
}

func makeFuncDecl(
  nm: in String, params: in List[Param], retTy: in TypeExpr, body: in Block, vis: in Option[Visibility]
): FunctionDecl {
  FunctionDecl(
    docComments = newList(),
    annotations = newList(),
    visibility = vis,
    isAsync = false,
    name = nm,
    generics = None,
    params = params,
    ret = Some(retTy),
    whereClause = None,
    contracts = newList(),
    body = Some(FBBlock(block = body)),
    span = sp()
  )
}

func funcItem(fd: in FunctionDecl, vis: in Option[Visibility]): Item {
  Item(docComments = newList(), annotations = newList(), visibility = vis, kind = IFunc(decl = fd), span = sp())
}

// String concatenation at the AST level.
func strCat(lhs: in Expr, rhs: in Expr): Expr {
  binop(BAdd, lhs, rhs)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2b. Pattern and match/if builder helpers.
// ─────────────────────────────────────────────────────────────────────────────
func wildcardPat(): Pattern {
  mkPat(PWildcard, sp())
}

func bindingPat(name: in String): Pattern {
  mkPat(PBinding(name = name, inner = None), sp())
}

// `PConstructor` with a single-segment head — matches `CaseName(args)`.
func ctorPat(caseName: in String, args: in List[Pattern]): Pattern {
  val segs: List[String] = newList()
  segs.add(caseName)
  mkPat(PConstructor(head = ModulePath(segments = segs, span = sp()), args = args), sp())
}

// n wildcard patterns — used for "don't care" union case fields in Ord arms.
func wildcardPats(n: in Int): List[Pattern] {
  val pats: List[Pattern] = newList()
  var i = 0
  while i < n {
    pats.add(wildcardPat())
    i = i + 1
  }
  pats
}

func mkArm(pat: in Pattern, bodyExpr: in Expr): MatchArm {
  MatchArm(pattern = pat, guard = None, body = EOBExpr(expr = bodyExpr), span = sp())
}

func mkArmBlock(pat: in Pattern, bodyBlock: in Block): MatchArm {
  MatchArm(pattern = pat, guard = None, body = EOBBlock(block = bodyBlock), span = sp())
}

func mkMatchExpr(scrutinee: in Expr, arms: in List[MatchArm]): Expr {
  mkExpr(EMatch(scrutinee = scrutinee, arms = arms), sp())
}

func boolLit(b: in Bool): Expr {
  mkExpr(ELiteral(lit = LBool(value = b)), sp())
}

// `if cond { thenBlock }` as a Statement — early-return pattern.
func stmtIf(cond: in Expr, thenBlock: in Block): Statement {
  mkStmt(
    SExpr(
      expr = mkExpr(
        EIf(cond = cond, thenBranch = EOBBlock(block = thenBlock), elseBranch = None, thenForm = false),
        sp()
      )
    ),
    sp()
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §2c. Union case binding helpers.
// ─────────────────────────────────────────────────────────────────────────────
// Generate binding names for a union case's fields, prefixed with `prefix`.
// Named fields use `prefix + fieldName`; positional fields use `prefix + "_f" + index`.
func caseBindingNames(c: in UnionCase, prefix: in String): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < c.fields.count {
    match c.fields[i] {
      case UFNamed(name, _, _) -> names.add(prefix + name)
      case UFPos(_, _) -> names.add(prefix + "_f" + toString(i))
    }
    i = i + 1
  }
  names
}

// Convert a list of binding names into `PBinding` patterns.
func caseBindingPats(names: in List[String]): List[Pattern] {
  val pats: List[Pattern] = newList()
  var i = 0
  while i < names.count {
    pats.add(bindingPat(names[i]))
    i = i + 1
  }
  pats
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Record field helpers.
// ─────────────────────────────────────────────────────────────────────────────
func collectFields(decl: in RecordDecl): List[FieldDecl] {
  val fields: List[FieldDecl] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(fd) -> {
        fields.add(fd)
      }
      case _ -> ()
    }
    i = i + 1
  }
  fields
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. @derive(Equals) synthesis.
// ─────────────────────────────────────────────────────────────────────────────
// Build `self.f == other.f and ...` for each field; `true` for empty records.
func equalsExprForFields(fields: in List[FieldDecl]): Expr {
  if fields.count == 0 {
    return mkExpr(ELiteral(lit = LBool(value = true)), sp())
  }
  var cmp = binop(BEq, memberOf(pathExpr("self"), fields[0].name), memberOf(pathExpr("other"), fields[0].name))
  var i = 1
  while i < fields.count {
    val next = binop(BEq, memberOf(pathExpr("self"), fields[i].name), memberOf(pathExpr("other"), fields[i].name))
    cmp = binop(BAnd, cmp, next)
    i = i + 1
  }
  cmp
}

// `TypeName.equals(self: in TypeName, other: in TypeName): Bool`
func synthesizeEqualsRecord(typeName: in String, decl: in RecordDecl, vis: in Option[Visibility]): Item {
  val fields = collectFields(decl)
  val body = blockReturn(equalsExprForFields(fields))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".equals", params, typeRef("Bool"), body, vis), vis)
}

// `TypeName.equals(self, other): Bool` for distinct types via the `value`
// field directly.  The lowered MDistinctType has a single `value: Inner`
// field (added in `lowerMDistinctType`); the body bypasses projection methods
// — `toInt`/`toString` are not synthesised on the lowered CLR class, and the
// F# emitter's own `equals` synthesis uses the same field-direct pattern
// (`ldfld value`).
func synthesizeEqualsDistinct(typeName: in String, vis: in Option[Visibility]): Item {
  val cmp = binop(BEq, memberOf(pathExpr("self"), "value"), memberOf(pathExpr("other"), "value"))
  val body = blockReturn(cmp)
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".equals", params, typeRef("Bool"), body, vis), vis)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. @derive(Hash) synthesis.
// ─────────────────────────────────────────────────────────────────────────────
// FNV-style: `var h: Int = 17; h = h * 31 + hashCode(self.f); ...`
func hashBodyForFields(fields: in List[FieldDecl]): Block {
  val stmts: List[Statement] = newList()
  stmts.add(stmtLocal("h", Some(typeRef("Int")), longLitOf(17i64)))
  var i = 0
  while i < fields.count {
    val fieldVal = memberOf(pathExpr("self"), fields[i].name)
    val hc = call1("hashCode", fieldVal)
    val h31 = binop(BMul, pathExpr("h"), longLitOf(31i64))
    val next = binop(BAdd, h31, hc)
    stmts.add(stmtAssign(pathExpr("h"), next))
    i = i + 1
  }
  blockStmtsReturn(stmts, pathExpr("h"))
}

// `TypeName.hash(self: in TypeName): Int`
func synthesizeHashRecord(typeName: in String, decl: in RecordDecl, vis: in Option[Visibility]): Item {
  val fields = collectFields(decl)
  val body = hashBodyForFields(fields)
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".hash", params, typeRef("Int"), body, vis), vis)
}

// `TypeName.hash(self: in TypeName): Int` for distinct types.
// Same `value`-field-direct strategy as `synthesizeEqualsDistinct` (see note there).
func synthesizeHashDistinct(typeName: in String, vis: in Option[Visibility]): Item {
  val body = blockReturn(call1("hashCode", memberOf(pathExpr("self"), "value")))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".hash", params, typeRef("Int"), body, vis), vis)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. @derive(Show) synthesis.
// ─────────────────────────────────────────────────────────────────────────────
// `"TypeName { f1 = " + toString(self.f1) + ", f2 = " + ... + " }"`
func showExprForFields(typeName: in String, fields: in List[FieldDecl]): Expr {
  if fields.count == 0 {
    return strLit(typeName + " {}")
  }
  var acc = strCat(
    strLit(typeName + " { " + fields[0].name + " = "),
    call1("toString", memberOf(pathExpr("self"), fields[0].name))
  )
  var i = 1
  while i < fields.count {
    acc = strCat(acc, strLit(", " + fields[i].name + " = "))
    acc = strCat(acc, call1("toString", memberOf(pathExpr("self"), fields[i].name)))
    i = i + 1
  }
  strCat(acc, strLit(" }"))
}

// `TypeName.show(self: in TypeName): String`
func synthesizeShowRecord(typeName: in String, decl: in RecordDecl, vis: in Option[Visibility]): Item {
  val fields = collectFields(decl)
  val body = blockReturn(showExprForFields(typeName, fields))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".show", params, typeRef("String"), body, vis), vis)
}

// `TypeName.show(self: in TypeName): String` for distinct types.
// Same `value`-field-direct strategy as the equals/hash synthesisers above.
func synthesizeShowDistinct(typeName: in String, vis: in Option[Visibility]): Item {
  val body = blockReturn(
    strCat(
      strCat(strLit(typeName + "("), call1("toString", memberOf(pathExpr("self"), "value"))),
      strLit(")")
    )
  )
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".show", params, typeRef("String"), body, vis), vis)
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. @generate(Json) synthesis.
// ─────────────────────────────────────────────────────────────────────────────
// Render a field value as a JSON string fragment.
// String fields get JSON-escaped (`\`, `"`, `\n`, `\r`, `\t` rewritten
// to their `\\`-prefixed escape sequences) and wrapped in double quotes
// so the resulting `toJson` output is valid JSON for the common escape
// classes.  The remaining C0 control characters (` `-``
// minus `\n`/`\r`/`\t`) are NOT yet escaped — that final-coverage
// follow-up needs the synthesiser to call a `__lyricJsonEscape`
// helper or `Std.Json.encodeString` so it can emit a `\uXXXX`
// sequence per remaining control byte.  Strings that happen to
// contain those bytes today produce technically-invalid JSON but
// the common chat/HTTP-message corpus avoids them.
// Primitive types use `toString`.
func jsonFieldExpr(fieldExpr: in Expr, ty: in TypeExpr): Expr {
  val typeName = match ty.kind {
    case TRef(path) -> {
      if path.segments.count > 0 {
        path.segments[path.segments.count - 1]
      } else {
        ""
      }
    }
    case _ -> ""
  }
  if typeName == "String" {
    // self.field
    //   .replace("\\", "\\\\")   // must be first so the \\ introduced
    //   .replace("\"", "\\\"")   //   by the next step isn't doubled
    //   .replace("\n", "\\n")
    //   .replace("\r", "\\r")
    //   .replace("\t", "\\t")
    val esc1 = methodCall2(fieldExpr, "replace", strLit("\\"), strLit("\\\\"))
    val esc2 = methodCall2(esc1, "replace", strLit("\""), strLit("\\\""))
    val esc3 = methodCall2(esc2, "replace", strLit("\n"), strLit("\\n"))
    val esc4 = methodCall2(esc3, "replace", strLit("\r"), strLit("\\r"))
    val esc5 = methodCall2(esc4, "replace", strLit("\t"), strLit("\\t"))
    strCat(strCat(strLit("\""), esc5), strLit("\""))
  } else {
    call1("toString", fieldExpr)
  }
}

// `"{\"f1\":<val1>,\"f2\":<val2>,...}"`
func toJsonExprForFields(fields: in List[FieldDecl]): Expr {
  if fields.count == 0 {
    return strLit("{}")
  }
  var acc = strCat(
    strLit("{\"" + fields[0].name + "\":"),
    jsonFieldExpr(memberOf(pathExpr("self"), fields[0].name), fields[0].ty)
  )
  var i = 1
  while i < fields.count {
    acc = strCat(acc, strLit(",\"" + fields[i].name + "\":"))
    acc = strCat(acc, jsonFieldExpr(memberOf(pathExpr("self"), fields[i].name), fields[i].ty))
    i = i + 1
  }
  strCat(acc, strLit("}"))
}

// `TypeName.toJson(self: in TypeName): String`
func synthesizeToJsonRecord(typeName: in String, decl: in RecordDecl, vis: in Option[Visibility]): Item {
  val fields = collectFields(decl)
  val body = blockReturn(toJsonExprForFields(fields))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".toJson", params, typeRef("String"), body, vis), vis)
}

// ─────────────────────────────────────────────────────────────────────────────
// §7b. @derive(Equals/Hash/Show/Ord) for unions.
// ─────────────────────────────────────────────────────────────────────────────
// Build `Equals` for a union type.
// Outer match on `self`; for each case, inner match on `other` — same-case
// arm compares fields pairwise, wildcard arm returns `false`.
func synthesizeEqualsUnion(typeName: in String, decl: in UnionDecl, vis: in Option[Visibility]): Item {
  val outerArms: List[MatchArm] = newList()
  var ci = 0
  while ci < decl.cases.count {
    val c = decl.cases[ci]
    val selfNames = caseBindingNames(c, "_s")
    val otherNames = caseBindingNames(c, "_o")
    val selfPats = caseBindingPats(selfNames)
    val otherPats = caseBindingPats(otherNames)
    val eqExpr = if selfNames.count == 0 {
      boolLit(true)
    } else {
      var acc = binop(BEq, pathExpr(selfNames[0]), pathExpr(otherNames[0]))
      var fi = 1
      while fi < selfNames.count {
        val next = binop(BEq, pathExpr(selfNames[fi]), pathExpr(otherNames[fi]))
        acc = binop(BAnd, acc, next)
        fi = fi + 1
      }
      acc
    }
    val innerArms: List[MatchArm] = newList()
    innerArms.add(mkArm(ctorPat(c.name, otherPats), eqExpr))
    innerArms.add(mkArm(wildcardPat(), boolLit(false)))
    val innerMatch = mkMatchExpr(pathExpr("other"), innerArms)
    outerArms.add(mkArm(ctorPat(c.name, selfPats), innerMatch))
    ci = ci + 1
  }
  val body = blockReturn(mkMatchExpr(pathExpr("self"), outerArms))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".equals", params, typeRef("Bool"), body, vis), vis)
}

// Build `Hash` for a union type.
// Each case arm starts the hash at its 0-based case index, then folds field
// hash codes using the FNV-style `h = h * 31 + hashCode(field)` chain.
func synthesizeHashUnion(typeName: in String, decl: in UnionDecl, vis: in Option[Visibility]): Item {
  val outerArms: List[MatchArm] = newList()
  var caseIdx = 0i64
  var ci = 0
  while ci < decl.cases.count {
    val c = decl.cases[ci]
    val names = caseBindingNames(c, "_f")
    val pats = caseBindingPats(names)
    val stmts: List[Statement] = newList()
    stmts.add(stmtLocal("h", Some(typeRef("Int")), longLitOf(caseIdx)))
    var fi = 0
    while fi < names.count {
      val hc = call1("hashCode", pathExpr(names[fi]))
      val h31 = binop(BMul, pathExpr("h"), longLitOf(31i64))
      val next = binop(BAdd, h31, hc)
      stmts.add(stmtAssign(pathExpr("h"), next))
      fi = fi + 1
    }
    val armBody = blockStmtsReturn(stmts, pathExpr("h"))
    outerArms.add(mkArmBlock(ctorPat(c.name, pats), armBody))
    caseIdx = caseIdx + 1i64
    ci = ci + 1
  }
  val body = blockReturn(mkMatchExpr(pathExpr("self"), outerArms))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".hash", params, typeRef("Int"), body, vis), vis)
}

// Build `Show` for a union type.
// Nullary cases: `"CaseName"`. Cases with fields: `"CaseName(f1, f2, ...)"`.
func synthesizeShowUnion(typeName: in String, decl: in UnionDecl, vis: in Option[Visibility]): Item {
  val outerArms: List[MatchArm] = newList()
  var ci = 0
  while ci < decl.cases.count {
    val c = decl.cases[ci]
    val names = caseBindingNames(c, "_f")
    val pats = caseBindingPats(names)
    val showExpr = if names.count == 0 {
      strLit(c.name)
    } else {
      var acc = strCat(strLit(c.name + "("), call1("toString", pathExpr(names[0])))
      var fi = 1
      while fi < names.count {
        acc = strCat(acc, strLit(", "))
        acc = strCat(acc, call1("toString", pathExpr(names[fi])))
        fi = fi + 1
      }
      strCat(acc, strLit(")"))
    }
    outerArms.add(mkArm(ctorPat(c.name, pats), showExpr))
    ci = ci + 1
  }
  val body = blockReturn(mkMatchExpr(pathExpr("self"), outerArms))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".show", params, typeRef("String"), body, vis), vis)
}

// Build `Ord` for a union type.
// Case ordering follows declaration order. For the same case, fields are
// compared lexicographically left-to-right using `<`/`>` with early return.
func synthesizeOrdUnion(typeName: in String, decl: in UnionDecl, vis: in Option[Visibility]): Item {
  val outerArms: List[MatchArm] = newList()
  var selfIdx = 0
  while selfIdx < decl.cases.count {
    val sc = decl.cases[selfIdx]
    val selfNames = caseBindingNames(sc, "_s")
    val selfPats = caseBindingPats(selfNames)
    val innerArms: List[MatchArm] = newList()
    var otherIdx = 0
    while otherIdx < decl.cases.count {
      val oc = decl.cases[otherIdx]
      if selfIdx == otherIdx {
        val otherNames = caseBindingNames(oc, "_o")
        val otherPats = caseBindingPats(otherNames)
        val stmts: List[Statement] = newList()
        var fi = 0
        while fi < selfNames.count {
          stmts.add(stmtIf(binop(BLt, pathExpr(selfNames[fi]), pathExpr(otherNames[fi])), blockReturn(longLitOf(-1i64))))
          stmts.add(stmtIf(binop(BGt, pathExpr(selfNames[fi]), pathExpr(otherNames[fi])), blockReturn(longLitOf(1i64))))
          fi = fi + 1
        }
        val sameBody = blockStmtsReturn(stmts, longLitOf(0i64))
        innerArms.add(mkArmBlock(ctorPat(oc.name, otherPats), sameBody))
      } else {
        val sign = if selfIdx < otherIdx { longLitOf(-1i64) } else { longLitOf(1i64) }
        innerArms.add(mkArmBlock(ctorPat(oc.name, wildcardPats(oc.fields.count)), blockReturn(sign)))
      }
      otherIdx = otherIdx + 1
    }
    val innerMatch = mkMatchExpr(pathExpr("other"), innerArms)
    outerArms.add(mkArm(ctorPat(sc.name, selfPats), innerMatch))
    selfIdx = selfIdx + 1
  }
  val body = blockReturn(mkMatchExpr(pathExpr("self"), outerArms))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".compare", params, typeRef("Int"), body, vis), vis)
}

// ─────────────────────────────────────────────────────────────────────────────
// §7c. @derive(Equals/Hash/Show/Ord) for enums.
// ─────────────────────────────────────────────────────────────────────────────
// Enums are nullary-only unions. Patterns use unqualified case names (the
// type checker resolves them from the scrutinee type).
func synthesizeEqualsEnum(typeName: in String, decl: in EnumDecl, vis: in Option[Visibility]): Item {
  val outerArms: List[MatchArm] = newList()
  var ci = 0
  while ci < decl.cases.count {
    val c = decl.cases[ci]
    val emptyPats: List[Pattern] = newList()
    val innerArms: List[MatchArm] = newList()
    innerArms.add(mkArm(ctorPat(c.name, emptyPats), boolLit(true)))
    innerArms.add(mkArm(wildcardPat(), boolLit(false)))
    val innerMatch = mkMatchExpr(pathExpr("other"), innerArms)
    val selfPats: List[Pattern] = newList()
    outerArms.add(mkArm(ctorPat(c.name, selfPats), innerMatch))
    ci = ci + 1
  }
  val body = blockReturn(mkMatchExpr(pathExpr("self"), outerArms))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".equals", params, typeRef("Bool"), body, vis), vis)
}

func synthesizeHashEnum(typeName: in String, decl: in EnumDecl, vis: in Option[Visibility]): Item {
  val outerArms: List[MatchArm] = newList()
  var caseIdx = 0i64
  var ci = 0
  while ci < decl.cases.count {
    val c = decl.cases[ci]
    val selfPats: List[Pattern] = newList()
    outerArms.add(mkArm(ctorPat(c.name, selfPats), longLitOf(caseIdx)))
    caseIdx = caseIdx + 1i64
    ci = ci + 1
  }
  val body = blockReturn(mkMatchExpr(pathExpr("self"), outerArms))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".hash", params, typeRef("Int"), body, vis), vis)
}

func synthesizeShowEnum(typeName: in String, decl: in EnumDecl, vis: in Option[Visibility]): Item {
  val outerArms: List[MatchArm] = newList()
  var ci = 0
  while ci < decl.cases.count {
    val c = decl.cases[ci]
    val selfPats: List[Pattern] = newList()
    outerArms.add(mkArm(ctorPat(c.name, selfPats), strLit(c.name)))
    ci = ci + 1
  }
  val body = blockReturn(mkMatchExpr(pathExpr("self"), outerArms))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".show", params, typeRef("String"), body, vis), vis)
}

func synthesizeOrdEnum(typeName: in String, decl: in EnumDecl, vis: in Option[Visibility]): Item {
  val outerArms: List[MatchArm] = newList()
  var selfIdx = 0
  while selfIdx < decl.cases.count {
    val sc = decl.cases[selfIdx]
    val innerArms: List[MatchArm] = newList()
    var otherIdx = 0
    while otherIdx < decl.cases.count {
      val oc = decl.cases[otherIdx]
      val resultVal = if selfIdx < otherIdx {
        longLitOf(-1i64)
      } else if selfIdx > otherIdx {
        longLitOf(1i64)
      } else {
        longLitOf(0i64)
      }
      val otherPats: List[Pattern] = newList()
      innerArms.add(mkArm(ctorPat(oc.name, otherPats), resultVal))
      otherIdx = otherIdx + 1
    }
    val innerMatch = mkMatchExpr(pathExpr("other"), innerArms)
    val selfPats: List[Pattern] = newList()
    outerArms.add(mkArm(ctorPat(sc.name, selfPats), innerMatch))
    selfIdx = selfIdx + 1
  }
  val body = blockReturn(mkMatchExpr(pathExpr("self"), outerArms))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".compare", params, typeRef("Int"), body, vis), vis)
}

// ─────────────────────────────────────────────────────────────────────────────
// §7d. @derive(Ord) for records and distinct types.
// ─────────────────────────────────────────────────────────────────────────────
// Field-by-field lexicographic comparison using `<`/`>` with early return.
func synthesizeOrdRecord(typeName: in String, decl: in RecordDecl, vis: in Option[Visibility]): Item {
  val fields = collectFields(decl)
  val stmts: List[Statement] = newList()
  var i = 0
  while i < fields.count {
    val sf = memberOf(pathExpr("self"), fields[i].name)
    val of_ = memberOf(pathExpr("other"), fields[i].name)
    stmts.add(stmtIf(binop(BLt, sf, of_), blockReturn(longLitOf(-1i64))))
    stmts.add(stmtIf(binop(BGt, sf, of_), blockReturn(longLitOf(1i64))))
    i = i + 1
  }
  val body = blockStmtsReturn(stmts, longLitOf(0i64))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".compare", params, typeRef("Int"), body, vis), vis)
}

// Same strategy as record Ord but through the single `value` field.
func synthesizeOrdDistinct(typeName: in String, vis: in Option[Visibility]): Item {
  val selfVal = memberOf(pathExpr("self"), "value")
  val otherVal = memberOf(pathExpr("other"), "value")
  val stmts: List[Statement] = newList()
  stmts.add(stmtIf(binop(BLt, selfVal, otherVal), blockReturn(longLitOf(-1i64))))
  stmts.add(stmtIf(binop(BGt, selfVal, otherVal), blockReturn(longLitOf(1i64))))
  val body = blockStmtsReturn(stmts, longLitOf(0i64))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".compare", params, typeRef("Int"), body, vis), vis)
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Per-item synthesis dispatch.
// ─────────────────────────────────────────────────────────────────────────────
// Returns true when a function named `name` already exists in `items`.
func funcAlreadyExists(items: in List[Item], name: in String): Bool {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(decl) -> {
        if decl.name == name {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// addIfNew avoids synthesising a function that already exists in the file's
// items (idempotency: a second deriveFile call on an already-derived file
// must not duplicate the synthesised helpers).  Also checks `synths` so
// that a type with both a `derives X` clause and a `@derive(X)` annotation
// does not add the same helper twice in one pass.
func addIfNew(synths: inout List[Item], existingItems: in List[Item], candidate: in Item, funcName: in String) {
  if not funcAlreadyExists(existingItems, funcName) and not funcAlreadyExists(synths, funcName) {
    synths.add(candidate)
  }
}

func deriveItem(item: in Item, existingItems: in List[Item], synths: inout List[Item]) {
  val anns = item.annotations
  // Synthesised helpers inherit the parent item's visibility so that
  // `pub @derive(Equals) record Point { ... }` produces a `pub Point.equals`
  // accessible to consumer packages.  Without this, every synthesised
  // helper was package-private and cross-package UFCS calls failed
  // visibility checks (#939).
  val vis = item.visibility
  match item.kind {
    case IRecord(decl) -> {
      if hasDeriveMarker(anns, "Equals") {
        addIfNew(synths, existingItems, synthesizeEqualsRecord(decl.name, decl, vis), decl.name + ".equals")
      }
      if hasDeriveMarker(anns, "Hash") {
        addIfNew(synths, existingItems, synthesizeHashRecord(decl.name, decl, vis), decl.name + ".hash")
      }
      if hasDeriveMarker(anns, "Show") {
        addIfNew(synths, existingItems, synthesizeShowRecord(decl.name, decl, vis), decl.name + ".show")
      }
      if hasDeriveMarker(anns, "Ord") {
        addIfNew(synths, existingItems, synthesizeOrdRecord(decl.name, decl, vis), decl.name + ".compare")
      }
      if hasGenerateMarker(anns, "Json") {
        addIfNew(synths, existingItems, synthesizeToJsonRecord(decl.name, decl, vis), decl.name + ".toJson")
      }
    }
    case IExposedRec(decl) -> {
      if hasDeriveMarker(anns, "Equals") {
        addIfNew(synths, existingItems, synthesizeEqualsRecord(decl.name, decl, vis), decl.name + ".equals")
      }
      if hasDeriveMarker(anns, "Hash") {
        addIfNew(synths, existingItems, synthesizeHashRecord(decl.name, decl, vis), decl.name + ".hash")
      }
      if hasDeriveMarker(anns, "Show") {
        addIfNew(synths, existingItems, synthesizeShowRecord(decl.name, decl, vis), decl.name + ".show")
      }
      if hasDeriveMarker(anns, "Ord") {
        addIfNew(synths, existingItems, synthesizeOrdRecord(decl.name, decl, vis), decl.name + ".compare")
      }
      if hasGenerateMarker(anns, "Json") {
        addIfNew(synths, existingItems, synthesizeToJsonRecord(decl.name, decl, vis), decl.name + ".toJson")
      }
    }
    case IDistinctType(decl) -> {
      val nm = decl.name
      var di = 0
      while di < decl.derives.count {
        val marker = decl.derives[di]
        if marker == "Equals" {
          addIfNew(synths, existingItems, synthesizeEqualsDistinct(nm, vis), nm + ".equals")
        }
        if marker == "Hash" {
          addIfNew(synths, existingItems, synthesizeHashDistinct(nm, vis), nm + ".hash")
        }
        if marker == "Show" {
          addIfNew(synths, existingItems, synthesizeShowDistinct(nm, vis), nm + ".show")
        }
        if marker == "Ord" {
          addIfNew(synths, existingItems, synthesizeOrdDistinct(nm, vis), nm + ".compare")
        }
        di = di + 1
      }
      if hasDeriveMarker(anns, "Equals") {
        addIfNew(synths, existingItems, synthesizeEqualsDistinct(nm, vis), nm + ".equals")
      }
      if hasDeriveMarker(anns, "Hash") {
        addIfNew(synths, existingItems, synthesizeHashDistinct(nm, vis), nm + ".hash")
      }
      if hasDeriveMarker(anns, "Show") {
        addIfNew(synths, existingItems, synthesizeShowDistinct(nm, vis), nm + ".show")
      }
      if hasDeriveMarker(anns, "Ord") {
        addIfNew(synths, existingItems, synthesizeOrdDistinct(nm, vis), nm + ".compare")
      }
    }
    case IUnion(decl) -> {
      if hasDeriveMarker(anns, "Equals") {
        addIfNew(synths, existingItems, synthesizeEqualsUnion(decl.name, decl, vis), decl.name + ".equals")
      }
      if hasDeriveMarker(anns, "Hash") {
        addIfNew(synths, existingItems, synthesizeHashUnion(decl.name, decl, vis), decl.name + ".hash")
      }
      if hasDeriveMarker(anns, "Show") {
        addIfNew(synths, existingItems, synthesizeShowUnion(decl.name, decl, vis), decl.name + ".show")
      }
      if hasDeriveMarker(anns, "Ord") {
        addIfNew(synths, existingItems, synthesizeOrdUnion(decl.name, decl, vis), decl.name + ".compare")
      }
    }
    case IEnum(decl) -> {
      if hasDeriveMarker(anns, "Equals") {
        addIfNew(synths, existingItems, synthesizeEqualsEnum(decl.name, decl, vis), decl.name + ".equals")
      }
      if hasDeriveMarker(anns, "Hash") {
        addIfNew(synths, existingItems, synthesizeHashEnum(decl.name, decl, vis), decl.name + ".hash")
      }
      if hasDeriveMarker(anns, "Show") {
        addIfNew(synths, existingItems, synthesizeShowEnum(decl.name, decl, vis), decl.name + ".show")
      }
      if hasDeriveMarker(anns, "Ord") {
        addIfNew(synths, existingItems, synthesizeOrdEnum(decl.name, decl, vis), decl.name + ".compare")
      }
    }
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
/// Walk all items in `file`, synthesise derive helper functions for every
/// `@derive(X)` / `@generate(Json)` annotation, and return a new SourceFile
/// with the synthesised items appended after the originals.
pub func deriveFile(file: in SourceFile): SourceFile {
  val synths: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    deriveItem(file.items[i], file.items, synths)
    i = i + 1
  }
  if synths.count == 0 {
    return file
  }
  val newItems: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    newItems.add(file.items[j])
    j = j + 1
  }
  var k = 0
  while k < synths.count {
    newItems.add(synths[k])
    k = k + 1
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = newItems,
    span = file.span
  )
}
