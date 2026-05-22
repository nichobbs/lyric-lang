// derives.l — Lyric.Derives
//
// AST-to-AST synthesiser for `@derive(Equals)`, `@derive(Hash)`,
// `@derive(Show)`, and `@generate(Json)` on records and distinct types.
// Mirrors the F# synthesis in `bootstrap/src/Lyric.Parser/JsonDerive.fs`
// and inline derive emission in `bootstrap/src/Lyric.Emitter/Emitter.fs`.
//
// The synthesiser appends `IFunc` items to the file's items list for each
// annotated type.  Both MSIL and JVM bridges call this pass after the
// contract elaborator and before codegen.
//
// Scope (docs/41 §9 Band 5 — #857):
//
//   Records / exposed records:
//   - @derive(Equals)  → `TypeName.equals(self, other): Bool`
//   - @derive(Hash)    → `TypeName.hash(self): Int`
//   - @derive(Show)    → `TypeName.show(self): String`
//   - @generate(Json)  → `TypeName.toJson(self): String`
//
//   Distinct types (via `derives` list on DistinctTypeDecl):
//   - derives Equals   → `TypeName.equals(self, other): Bool`
//   - derives Hash     → `TypeName.hash(self): Int`
//   - derives Show     → `TypeName.show(self): String`
//
// Union / enum derives are deferred; the F# bootstrap handles them for
// --target dotnet-legacy.
//
// Public surface:
//
//   pub func deriveFile(file: in SourceFile): SourceFile
//

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
        case ABare(nm, _) -> { return Some(nm) }
        case ALiteral(value, _) -> {
          match value {
            case AVIdent(nm, _) -> { return Some(nm) }
            case _ -> { return None }
          }
        }
        case AAName(_, _, _) -> { return None }
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
        if nm == marker { return true }
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
        if nm == marker { return true }
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

func sp(): Span { syntheticSpan() }

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
  mkExpr(ELiteral(lit = LInt(value = n, suffix = NoIntSuffix)), sp())
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

func emptyList[A](): List[A] { newList() }

func makeParam(nm: in String, ty: in TypeExpr): Param {
  Param(mode = PMIn, name = nm, ty = ty, dflt = None, span = sp())
}

func makeFuncDecl(nm: in String, params: in List[Param], retTy: in TypeExpr, body: in Block): FunctionDecl {
  FunctionDecl(
    docComments = newList(),
    annotations = newList(),
    visibility  = None,
    isAsync     = false,
    name        = nm,
    generics    = None,
    params      = params,
    ret         = Some(retTy),
    whereClause = None,
    contracts   = newList(),
    body        = Some(FBBlock(block = body)),
    span        = sp()
  )
}

func funcItem(fd: in FunctionDecl): Item {
  Item(
    docComments = newList(),
    annotations = newList(),
    visibility  = None,
    kind        = IFunc(decl = fd),
    span        = sp()
  )
}

// String concatenation at the AST level.
func strCat(lhs: in Expr, rhs: in Expr): Expr {
  binop(BAdd, lhs, rhs)
}


// ─────────────────────────────────────────────────────────────────────────────
// §3. Record field helpers.
// ─────────────────────────────────────────────────────────────────────────────

func collectFields(decl: in RecordDecl): List[FieldDecl] {
  val fields: List[FieldDecl] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(fd) -> { fields.add(fd) }
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
  var cmp = binop(BEq,
    memberOf(pathExpr("self"),  fields[0].name),
    memberOf(pathExpr("other"), fields[0].name))
  var i = 1
  while i < fields.count {
    val next = binop(BEq,
      memberOf(pathExpr("self"),  fields[i].name),
      memberOf(pathExpr("other"), fields[i].name))
    cmp = binop(BAnd, cmp, next)
    i = i + 1
  }
  cmp
}

// `TypeName.equals(self: in TypeName, other: in TypeName): Bool`
func synthesizeEqualsRecord(typeName: in String, decl: in RecordDecl): Item {
  val fields = collectFields(decl)
  val body   = blockReturn(equalsExprForFields(fields))
  val params: List[Param] = newList()
  params.add(makeParam("self",  typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".equals", params, typeRef("Bool"), body))
}

// `TypeName.equals(self, other): Bool` for distinct types via projection method.
func synthesizeEqualsDistinct(typeName: in String, projMethod: in String): Item {
  val cmp  = binop(BEq, call1(projMethod, pathExpr("self")), call1(projMethod, pathExpr("other")))
  val body = blockReturn(cmp)
  val params: List[Param] = newList()
  params.add(makeParam("self",  typeRef(typeName)))
  params.add(makeParam("other", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".equals", params, typeRef("Bool"), body))
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
    val hc       = call1("hashCode", fieldVal)
    val h31      = binop(BMul, pathExpr("h"), longLitOf(31i64))
    val next     = binop(BAdd, h31, hc)
    stmts.add(stmtAssign(pathExpr("h"), next))
    i = i + 1
  }
  blockStmtsReturn(stmts, pathExpr("h"))
}

// `TypeName.hash(self: in TypeName): Int`
func synthesizeHashRecord(typeName: in String, decl: in RecordDecl): Item {
  val fields = collectFields(decl)
  val body   = hashBodyForFields(fields)
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".hash", params, typeRef("Int"), body))
}

// `TypeName.hash(self: in TypeName): Int` for distinct types.
func synthesizeHashDistinct(typeName: in String, projMethod: in String): Item {
  val body = blockReturn(call1("hashCode", call1(projMethod, pathExpr("self"))))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".hash", params, typeRef("Int"), body))
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
    call1("toString", memberOf(pathExpr("self"), fields[0].name)))
  var i = 1
  while i < fields.count {
    acc = strCat(acc, strLit(", " + fields[i].name + " = "))
    acc = strCat(acc, call1("toString", memberOf(pathExpr("self"), fields[i].name)))
    i = i + 1
  }
  strCat(acc, strLit(" }"))
}

// `TypeName.show(self: in TypeName): String`
func synthesizeShowRecord(typeName: in String, decl: in RecordDecl): Item {
  val fields = collectFields(decl)
  val body   = blockReturn(showExprForFields(typeName, fields))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".show", params, typeRef("String"), body))
}

// `TypeName.show(self: in TypeName): String` for distinct types.
func synthesizeShowDistinct(typeName: in String, projMethod: in String): Item {
  val body = blockReturn(
    strCat(strCat(strLit(typeName + "("),
                  call1("toString", call1(projMethod, pathExpr("self")))),
           strLit(")")))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".show", params, typeRef("String"), body))
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
      if path.segments.count > 0 { path.segments[path.segments.count - 1] } else { "" }
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
    val esc2 = methodCall2(esc1,      "replace", strLit("\""), strLit("\\\""))
    val esc3 = methodCall2(esc2,      "replace", strLit("\n"), strLit("\\n"))
    val esc4 = methodCall2(esc3,      "replace", strLit("\r"), strLit("\\r"))
    val esc5 = methodCall2(esc4,      "replace", strLit("\t"), strLit("\\t"))
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
    jsonFieldExpr(memberOf(pathExpr("self"), fields[0].name), fields[0].ty))
  var i = 1
  while i < fields.count {
    acc = strCat(acc, strLit(",\"" + fields[i].name + "\":"))
    acc = strCat(acc, jsonFieldExpr(memberOf(pathExpr("self"), fields[i].name), fields[i].ty))
    i = i + 1
  }
  strCat(acc, strLit("}"))
}

// `TypeName.toJson(self: in TypeName): String`
func synthesizeToJsonRecord(typeName: in String, decl: in RecordDecl): Item {
  val fields = collectFields(decl)
  val body   = blockReturn(toJsonExprForFields(fields))
  val params: List[Param] = newList()
  params.add(makeParam("self", typeRef(typeName)))
  funcItem(makeFuncDecl(typeName + ".toJson", params, typeRef("String"), body))
}


// ─────────────────────────────────────────────────────────────────────────────
// §8. Distinct-type projection method name.
// ─────────────────────────────────────────────────────────────────────────────

// Map an underlying primitive type name to the UFCS projection method
// that Lyric synthesises automatically on distinct types.
func projectionMethod(underlyingName: in String): String {
  if underlyingName == "Int"    { return "toInt" }
  if underlyingName == "Long"   { return "toLong" }
  if underlyingName == "UInt"   { return "toUInt" }
  if underlyingName == "ULong"  { return "toULong" }
  if underlyingName == "Byte"   { return "toByte" }
  if underlyingName == "Float"  { return "toFloat" }
  if underlyingName == "Double" { return "toDouble" }
  if underlyingName == "String" { return "toString" }
  // Distinct-type wrappers around Bool need `.toBool()` projection;
  // without this arm they would fall through to the `"toValue"`
  // fallback and reference a method that doesn't exist on Bool.
  if underlyingName == "Bool"   { return "toBool" }
  "toValue"
}

func lastSegment(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count > 0 { path.segments[path.segments.count - 1] } else { "" }
    }
    case _ -> ""
  }
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
        if decl.name == name { return true }
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
  match item.kind {
    case IRecord(decl) -> {
      if hasDeriveMarker(anns, "Equals")  { addIfNew(synths, existingItems, synthesizeEqualsRecord(decl.name, decl), decl.name + ".equals") }
      if hasDeriveMarker(anns, "Hash")    { addIfNew(synths, existingItems, synthesizeHashRecord(decl.name, decl), decl.name + ".hash") }
      if hasDeriveMarker(anns, "Show")    { addIfNew(synths, existingItems, synthesizeShowRecord(decl.name, decl), decl.name + ".show") }
      if hasGenerateMarker(anns, "Json")  { addIfNew(synths, existingItems, synthesizeToJsonRecord(decl.name, decl), decl.name + ".toJson") }
    }
    case IExposedRec(decl) -> {
      if hasDeriveMarker(anns, "Equals")  { addIfNew(synths, existingItems, synthesizeEqualsRecord(decl.name, decl), decl.name + ".equals") }
      if hasDeriveMarker(anns, "Hash")    { addIfNew(synths, existingItems, synthesizeHashRecord(decl.name, decl), decl.name + ".hash") }
      if hasDeriveMarker(anns, "Show")    { addIfNew(synths, existingItems, synthesizeShowRecord(decl.name, decl), decl.name + ".show") }
      if hasGenerateMarker(anns, "Json")  { addIfNew(synths, existingItems, synthesizeToJsonRecord(decl.name, decl), decl.name + ".toJson") }
    }
    case IDistinctType(decl) -> {
      val projName = projectionMethod(lastSegment(decl.underlying))
      val nm       = decl.name
      var di = 0
      while di < decl.derives.count {
        val marker = decl.derives[di]
        if marker == "Equals" { addIfNew(synths, existingItems, synthesizeEqualsDistinct(nm, projName), nm + ".equals") }
        if marker == "Hash"   { addIfNew(synths, existingItems, synthesizeHashDistinct(nm, projName), nm + ".hash") }
        if marker == "Show"   { addIfNew(synths, existingItems, synthesizeShowDistinct(nm, projName), nm + ".show") }
        di = di + 1
      }
      if hasDeriveMarker(anns, "Equals") { addIfNew(synths, existingItems, synthesizeEqualsDistinct(nm, projName), nm + ".equals") }
      if hasDeriveMarker(anns, "Hash")   { addIfNew(synths, existingItems, synthesizeHashDistinct(nm, projName), nm + ".hash") }
      if hasDeriveMarker(anns, "Show")   { addIfNew(synths, existingItems, synthesizeShowDistinct(nm, projName), nm + ".show") }
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
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = newItems,
    span            = file.span
  )
}
