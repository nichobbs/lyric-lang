//! Ui.Routes — the route generator of docs/65-ui-library-sketch.md §6.1
//! (D151).
//!
//! For a union `T` annotated `@generate(Ui.Routes)`, whose every case
//! carries `@path("/literal/{field}/...")`, it emits:
//!
//!   pub func parseT(url: in String): Option[T]   the route `url` names
//!   pub func tUrl(r: in T): String              the URL of route `r`
//!
//! A `{name}` segment binds the case field `name`; every field of the case
//! appears in its path exactly once.  A field is a `String`, `Int` or
//! `Long`, an enum declared in the same file (its case name is the segment),
//! or a distinct or range type over one of those declared in the same file
//! (a value outside the range does not match).  `{name:Long}` (or `:Int`,
//! `:String`) names the segment's type, for a distinct type declared
//! elsewhere: the segment is parsed as that type and converted with the
//! field type's `tryFrom`.  `parseT` tries the cases
//! in declaration order and ignores the fragment; segments are
//! percent-decoded, and `tUrl` percent-encodes field values.
//!
//! A case annotation `@query(field)` (or `@query(field, "name")`, to name the
//! query parameter) makes `field` a query field instead of a path segment
//! (an annotation sits on the case because a case's parameters take none):
//!
//!   @path("/customers/search")
//!   @query(term)
//!   @query(page, "p")
//!   case CustomerSearch(term: Option[String], page: Option[Int])
//!
//! A query field is read from `?name=value` and must be an `Option` of one of
//! the types above.  An absent parameter is `None`; one
//! whose value does not parse (or holds an invalid escape) makes the case not
//! match.  `tUrl` writes a `Some` field as `name=value` after the path
//! (percent-encoded, in field order) and leaves a `None` out, so `parseT` of
//! `tUrl(r)` is `r`.
//!
//! The generated code refers to `Ui.Routing` through the alias
//! `GenRouting`.
@runtime_checked
@io
package Ui.Routes

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.GeneratorSdk

// ─── Model ────────────────────────────────────────────────────────────────────
// How a field's value is read from and written to a path segment.
union Param {
  case TextParam(distinct: Option[String])
  case NumberParam(isInt: Bool, distinct: Option[String])
  case ChoiceParam(enumName: String, cases: List[String])
}

union Segment {
  case Literal(text: String)
  // `{name}`, or `{name:Type}` naming the segment's text type.
  case Field(name: String, hint: Option[String])
}

record RouteField {
  name: String
  // The field's type as written: `Option[T]` for a query field.
  typeText: String
  // The parsed value's type, without `Option` for a query field.
  valueType: String
  param: Param
  // The query parameter name, for a `@query` field.
  query: Option[String]
}

record RouteCase {
  name: String
  segments: List[Segment]
  fields: List[RouteField]
}

record Model {
  typeName: String
  lower: String
  cases: List[RouteCase]
}

// ─── Entry point ──────────────────────────────────────────────────────────────
pub func generateSource(req: in GeneratorRequest): GeneratorResponse {
  val diags: List[GeneratorDiagnostic] = newList()
  val model = buildModel(req, diags)
  if diags.count > 0 {
    return response("", diags)
  }
  response(emit(model), diags)
}

func response(src: in String, diags: in List[GeneratorDiagnostic]): GeneratorResponse {
  val imports: List[String] = newList()
  if src != "" {
    imports.add("import Std.Core")
    imports.add("import Std.Collections")
    imports.add("import Ui.Routing as GenRouting")
  }
  GeneratorResponse(lyricSource = src, additionalImports = imports.toArray(), diagnostics = diags.toArray())
}

func report(diags: in List[GeneratorDiagnostic], code: in String, message: in String): Unit {
  diags.add(GeneratorDiagnostic(severity = Error, message = message, code = Some(value = code)))
}

// ─── Building the model ───────────────────────────────────────────────────────
func buildModel(req: in GeneratorRequest, diags: in List[GeneratorDiagnostic]): Model {
  val td = req.typeDescriptor
  val cases: List[RouteCase] = newList()
  val model = Model(typeName = td.name, lower = lowerFirst(td.name), cases = cases)
  val isUnion = match td.kind { case Union -> true; case _ -> false }
  if not isUnion {
    report(diags, "RT001", "Ui.Routes derives routes from a union; '" + td.name + "' is not one")
    return model
  }
  if td.typeParams.length > 0 {
    report(diags, "RT006", "Ui.Routes cannot derive routes for the generic union '" + td.name + "'")
    return model
  }
  if td.cases.length == 0 {
    report(diags, "RT001", "the route union '" + td.name + "' has no cases")
    return model
  }
  var i = 0
  while i < td.cases.length {
    match caseOf(req, td.cases[i], diags) {
      case Some(rc) -> cases.add(rc)
      case None -> ()
    }
    i += 1
  }
  checkAmbiguity(cases, diags)
  model
}

func caseOf(req: in GeneratorRequest, c: in CaseDescriptor, diags: in List[GeneratorDiagnostic]): Option[RouteCase] {
  val pathText = match pathOf(c.annotations) {
    case Some(p) -> p
    case None -> {
      report(diags, "RT002", "route case '" + c.name + "' needs @path(\"/...\")")
      return None
    }
  }
  if not Str.startsWith(pathText, "/") or Str.contains(pathText, "?") or Str.contains(pathText, "#") {
    report(
      diags,
      "RT002",
      "the path of route case '" + c.name + "' must start with '/' and hold no query or fragment: " + pathText
    )
    return None
  }
  val segments: List[Segment] = newList()
  for raw in Str.split(pathText, "/") {
    if raw.length > 0 {
      if Str.startsWith(raw, "{") and Str.endsWith(raw, "}") and raw.length > 2 {
        val inner = raw.substring(1, raw.length - 2)
        match Str.indexOf(inner, ":") {
          case None -> segments.add(Field(name = inner, hint = None))
          case Some(colon) -> {
            val hint = Str.trim(inner.substring(colon + 1, inner.length - colon - 1))
            if hint != "String" and hint != "Int" and hint != "Long" {
              report(
                diags,
                "RT002",
                "segment " + raw + " of route case '" + c.name + "' names type '" + hint +
                  "'; a segment type is String, Int or Long"
              )
              return None
            }
            segments.add(Field(name = Str.trim(inner.substring(0, colon)), hint = Some(value = hint)))
          }
        }
      } else if isUnreservedText(raw) {
        segments.add(Literal(text = raw))
      } else {
        report(
          diags,
          "RT002",
          "segment '" + raw + "' of route case '" + c.name + "' is neither a {field} nor plain text " +
            "(letters, digits, '-', '.', '_', '~')"
        )
        return None
      }
    }
  }
  val queryDecls = queryDeclsOf(c, diags)
  if diags.count > 0 {
    return None
  }
  val fields: List[RouteField] = newList()
  val queryNames: List[String] = newList()
  var k = 0
  while k < c.fields.length {
    val f = c.fields[k]
    if f.name == "" {
      report(diags, "RT003", "route case '" + c.name + "' has a positional field; route fields must be named")
      return None
    }
    val ty = Str.trim(f.fieldType.name)
    val queryParam = queryParamFor(queryDecls, f.name)
    if hasValue(queryParam) {
      match queryFieldOf(req, c, f, queryParam, diags) {
        case Some(qf) -> {
          match qf.query {
            case Some(qn) -> {
              if queryNames.contains(qn) {
                report(diags, "RT007", "route case '" + c.name + "' reads the query parameter '" + qn + "' twice")
                return None
              }
              queryNames.add(qn)
            }
            case None -> ()
          }
          fields.add(qf)
        }
        case None -> return None
      }
    } else {
      val param: Option[Param] = match hintFor(segments, f.name) {
        case Some(h) -> Some(value = hintedParam(h, ty))
        case None -> paramOf(req, ty, 0)
      }
      match param {
        case Some(p) -> fields.add(
          RouteField(name = f.name, typeText = f.fieldType.name, valueType = ty, param = p, query = None)
        )
        case None -> {
          report(
            diags,
            "RT004",
            "field '" + f.name + "' of route case '" + c.name + "' has type " + f.fieldType.name +
              ", which a path segment cannot hold; use String, Int, Long, or an enum, distinct or range type declared in this file, " +
              "or name the segment's type, as in {" +
              f.name +
              ":Long}"
          )
          return None
        }
      }
    }
    k += 1
  }
  // Every path field appears exactly once, a query field never, and every
  // {name} is a field.
  for f in fields {
    var uses = 0
    for s in segments {
      match s {
        case Field(n, _) -> {
          if n == f.name {
            uses += 1
          }
        }
        case Literal(_) -> ()
      }
    }
    if isQuery(f) {
      if uses != 0 {
        report(
          diags,
          "RT007",
          "field '" + f.name + "' of route case '" + c.name + "' is a @query field, so it cannot also be a path segment"
        )
        return None
      }
    } else if uses != 1 {
      report(
        diags,
        "RT003",
        "field '" + f.name + "' of route case '" + c.name + "' appears " + Str.fromInt(uses) +
          " times in its path; it must appear once"
      )
      return None
    }
  }
  for s in segments {
    match s {
      case Field(n, _) -> {
        var known = false
        for f in fields {
          if f.name == n {
            known = true
          }
        }
        if not known {
          report(diags, "RT003", "path segment {" + n + "} of route case '" + c.name + "' names no field of the case")
          return None
        }
      }
      case Literal(_) -> ()
    }
  }
  Some(value = RouteCase(name = c.name, segments = segments, fields = fields))
}

func isQuery(f: in RouteField): Bool {
  return match f.query { case Some(_) -> true; case None -> false }
}

func hasValue(o: in Option[String]): Bool {
  return match o { case Some(_) -> true; case None -> false }
}

// One `@query(field)` / `@query(field, "name")` annotation of a case.
record QueryDecl {
  field: String
  param: String
}

func queryDeclsOf(c: in CaseDescriptor, diags: in List[GeneratorDiagnostic]): List[QueryDecl] {
  val decls: List[QueryDecl] = newList()
  var i = 0
  while i < c.annotations.length {
    val a = c.annotations[i]
    if a.name == "query" {
      if a.args.length < 1 or a.args.length > 2 {
        report(
          diags,
          "RT007",
          "@query on route case '" + c.name +
            "' takes the field name and, optionally, the parameter name: @query(field, \"name\")"
        )
        return decls
      }
      val field = Str.trim(a.args[0])
      var known = false
      var k = 0
      while k < c.fields.length {
        if c.fields[k].name == field {
          known = true
        }
        k += 1
      }
      if not known {
        report(diags, "RT007", "@query(" + field + ") on route case '" + c.name + "' names no field of the case")
        return decls
      }
      for d in decls {
        if d.field == field {
          report(diags, "RT007", "route case '" + c.name + "' marks field '" + field + "' as @query twice")
          return decls
        }
      }
      var param = field
      if a.args.length == 2 {
        match stringLiteralText(a.args[1]) {
          case Some(n) -> {
            if n.length == 0 {
              report(diags, "RT007", "@query(" + field + ") on route case '" + c.name + "' names an empty parameter")
              return decls
            }
            param = n
          }
          case None -> {
            report(
              diags,
              "RT007",
              "@query(" + field + ", ...) on route case '" + c.name + "' takes a plain string literal, the parameter name"
            )
            return decls
          }
        }
      }
      decls.add(QueryDecl(field = field, param = param))
    }
    i += 1
  }
  return decls
}

func queryParamFor(decls: in List[QueryDecl], field: in String): Option[String] {
  for d in decls {
    if d.field == field {
      return Some(value = d.param)
    }
  }
  return None
}

// A `@query` field: `Option[T]` for a type `T` a query value can hold, read
// from the parameter `param`.
func queryFieldOf(
  req: in GeneratorRequest,
  c: in CaseDescriptor,
  f: in FieldDescriptor,
  param: in Option[String],
  diags: in List[GeneratorDiagnostic],
): Option[RouteField] {
  val isOption = match f.fieldType.kind { case OptionType -> true; case _ -> false }
  if not isOption or f.fieldType.typeArgs.length != 1 {
    report(
      diags,
      "RT007",
      "@query field '" + f.name + "' of route case '" + c.name + "' has type " + f.fieldType.name +
        "; a query parameter may be absent, so its type is Option[T]"
    )
    return None
  }
  val inner = Str.trim(f.fieldType.typeArgs[0])
  return match paramOf(req, inner, 0) {
    case Some(p) -> Some(
      value = RouteField(
        name = f.name,
        typeText = f.fieldType.name,
        valueType = inner,
        param = p,
        query = param
      )
    )
    case None -> {
      report(
        diags,
        "RT004",
        "@query field '" + f.name + "' of route case '" + c.name + "' holds " + inner +
          ", which a query value cannot hold; use String, Int, Long, or an enum, distinct or range type declared in this file"
      )
      None
    }
  }
}

// Two cases whose paths have the same literals and fields in the same places
// would match the same URLs: the later one could never be reached.
func checkAmbiguity(cases: in List[RouteCase], diags: in List[GeneratorDiagnostic]): Unit {
  var i = 0
  while i < cases.count {
    var j = i + 1
    while j < cases.count {
      if shapeKey(cases[i]) == shapeKey(cases[j]) {
        report(
          diags,
          "RT005",
          "route cases '" + cases[i].name + "' and '" + cases[j].name + "' have the same path shape, so '" + cases[j].name +
            "' is never matched"
        )
      }
      j += 1
    }
    i += 1
  }
}

func shapeKey(c: in RouteCase): String {
  var key = ""
  for s in c.segments {
    val part = match s { case Literal(t) -> t; case Field(_, _) -> "{}" }
    key = key + "/" + part
  }
  key
}

func pathOf(anns: in slice[AnnotationDescriptor]): Option[String] {
  var i = 0
  while i < anns.length {
    if anns[i].name == "path" and anns[i].args.length == 1 {
      return stringLiteralText(anns[i].args[0])
    }
    i += 1
  }
  None
}

// The text of a plain string literal's source (`"/a/{b}"` is `/a/{b}`), or
// `None` for anything else: an escape or interpolation has no place in a
// path.
func stringLiteralText(src: in String): Option[String] {
  if src.length < 2 or not Str.startsWith(src, "\"") or not Str.endsWith(src, "\"") {
    return None
  }
  val inner = src.substring(1, src.length - 2)
  if Str.contains(inner, "\\") or Str.contains(inner, "$") or Str.contains(inner, "\"") {
    return None
  }
  Some(value = inner)
}

func isUnreservedText(s: in String): Bool {
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    val ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '.' or
      c == '_' or
      c == '~'
    if not ok {
      return false
    }
    i += 1
  }
  s.length > 0
}

// The type hint of segment `{name:Type}`, if the path gives one.
func hintFor(segments: in List[Segment], name: in String): Option[String] {
  for s in segments {
    match s {
      case Field(n, hint) -> {
        if n == name {
          return hint
        }
      }
      case Literal(_) -> ()
    }
  }
  None
}

// A field of type `ty` read from a segment of type `hint`: the field's type
// itself when they agree, else a distinct type over the hint, built with
// `tryFrom`.
func hintedParam(hint: in String, ty: in String): Param {
  val distinct: Option[String] = if ty == hint { None } else { Some(value = ty) }
  if hint == "String" {
    TextParam(distinct = distinct)
  } else {
    NumberParam(isInt = hint == "Int", distinct = distinct)
  }
}

func paramOf(req: in GeneratorRequest, ty: in String, depth: in Int): Option[Param] {
  if ty == "String" {
    return Some(value = TextParam(distinct = None))
  }
  if ty == "Int" {
    return Some(value = NumberParam(isInt = true, distinct = None))
  }
  if ty == "Long" {
    return Some(value = NumberParam(isInt = false, distinct = None))
  }
  if depth > 8 {
    return None
  }
  match declarationNamed(req, ty) {
    case None -> None
    case Some(d) -> match d.kind {
      case DeclaredEnum -> {
        val names: List[String] = newList()
        var i = 0
        while i < d.cases.length {
          names.add(d.cases[i].name)
          i += 1
        }
        if names.count == 0 {
          None
        } else {
          Some(value = ChoiceParam(enumName = d.name, cases = names))
        }
      }
      case DeclaredAlias -> match d.underlying {
        case Some(u) -> paramOf(req, Str.trim(u), depth + 1)
        case None -> None
      }
      case DeclaredDistinct -> {
        val under = match d.underlying { case Some(u) -> Str.trim(u); case None -> "" }
        if under == "String" {
          Some(value = TextParam(distinct = Some(value = d.name)))
        } else if under == "Int" {
          Some(value = NumberParam(isInt = true, distinct = Some(value = d.name)))
        } else if under == "Long" {
          Some(value = NumberParam(isInt = false, distinct = Some(value = d.name)))
        } else {
          None
        }
      }
    }
  }
}

// ─── Names and literals ───────────────────────────────────────────────────────
func lowerFirst(s: in String): String {
  if s.length == 0 {
    s
  } else {
    Str.toLower(s.substring(0, 1)) + s.substring(1, s.length - 1)
  }
}

func upperFirst(s: in String): String {
  if s.length == 0 {
    s
  } else {
    Str.toUpper(s.substring(0, 1)) + s.substring(1, s.length - 1)
  }
}

func quoted(s: in String): String {
  "\"" + s + "\""
}

// ─── Emission ─────────────────────────────────────────────────────────────────
func emit(m: in Model): String {
  val parts: List[String] = newList()
  parts.add(emitParse(m))
  for c in m.cases {
    parts.add(emitCaseParse(m, c))
    for f in c.fields {
      parts.add(emitFieldParse(m, c, f))
      if isQuery(f) {
        parts.add(emitQueryParse(m, c, f))
        parts.add(emitQueryText(m, c, f))
      }
      match f.param {
        case ChoiceParam(enumName, cases) -> parts.add(emitChoiceText(m, c, f, enumName, cases))
        case _ -> ()
      }
    }
  }
  parts.add(emitUrl(m))
  Str.joinList("\n", parts)
}

func caseParseName(m: in Model, c: in RouteCase): String {
  "parse" + m.typeName + c.name
}

func fieldParseName(m: in Model, c: in RouteCase, f: in RouteField): String {
  m.lower + c.name + upperFirst(f.name) + "Segment"
}

func queryParseName(m: in Model, c: in RouteCase, f: in RouteField): String {
  m.lower + c.name + upperFirst(f.name) + "Query"
}

func queryTextName(m: in Model, c: in RouteCase, f: in RouteField): String {
  m.lower + c.name + upperFirst(f.name) + "QueryText"
}

func choiceTextName(m: in Model, c: in RouteCase, f: in RouteField): String {
  m.lower + c.name + upperFirst(f.name) + "Text"
}

func emitParse(m: in Model): String {
  var s = "/// The `" + m.typeName + "` that `url` names, or `None`.  Cases are tried in declaration order;\n" +
    "/// the fragment is ignored, and the query is read only by `@query` fields.\npub func parse" +
    m.typeName +
    "(url: in String): Option[" +
    m.typeName +
    "] {\n  val segments = match GenRouting.pathSegments(url) {\n    case Some(s) -> s\n    case None -> return None\n  }\n"
  for c in m.cases {
    s = s + "  match " + caseParseName(m, c) +
      "(segments, url) {\n    case Some(r) -> return Some(value = r)\n    case None -> ()\n  }\n"
  }
  s + "  return None\n}\n"
}

func emitCaseParse(m: in Model, c: in RouteCase): String {
  var s = "func " + caseParseName(m, c) + "(segments: in List[String], url: in String): Option[" + m.typeName +
    "] {\n  if segments.count != " +
    Str.fromInt(c.segments.count) +
    " {\n    return None\n  }\n"
  var i = 0
  for seg in c.segments {
    match seg {
      case Literal(t) -> {
        s = s + "  if segments[" + Str.fromInt(i) + "] != " + quoted(t) + " {\n    return None\n  }\n"
      }
      case Field(_, _) -> ()
    }
    i += 1
  }
  var args = ""
  var first = true
  for f in c.fields {
    args = args + (if first { "" } else { ", " }) + f.name + " = " + f.name
    first = false
  }
  val built = if c.fields.count == 0 { m.typeName + "." + c.name } else { m.typeName + "." + c.name + "(" + args + ")" }
  var body = "Some(value = " + built + ")"
  // Nest one match per field, innermost last, so every field is bound when
  // the case is built.
  var k = c.fields.count - 1
  while k >= 0 {
    val f = c.fields[k]
    val source = if isQuery(f) {
      queryParseName(m, c, f) + "(url"
    } else {
      fieldParseName(m, c, f) + "(segments[" + Str.fromInt(segmentIndex(c, f.name)) + "]"
    }
    body = "match " + source + ") {\n    case Some(" + f.name + ") -> " + body + "\n    case None -> None\n  }"
    k -= 1
  }
  s + "  return " + body + "\n}\n"
}

func segmentIndex(c: in RouteCase, name: in String): Int {
  var i = 0
  for seg in c.segments {
    match seg {
      case Field(n, _) -> {
        if n == name {
          return i
        }
      }
      case Literal(_) -> ()
    }
    i += 1
  }
  -1
}

func emitFieldParse(m: in Model, c: in RouteCase, f: in RouteField): String {
  val head = "func " + fieldParseName(m, c, f) + "(text: in String): Option[" + f.valueType + "] {\n  return "
  val body = match f.param {
    case TextParam(distinct) -> match distinct {
      case Some(t) -> "Some(value = " + t + ".from(text))"
      case None -> "Some(value = text)"
    }
    case NumberParam(isInt, distinct) -> {
      val parsed = if isInt { "GenRouting.intSegment(text)" } else { "GenRouting.longSegment(text)" }
      match distinct {
        case Some(t) -> "match " + parsed + " {\n    case Some(n) -> match " + t +
          ".tryFrom(n) {\n      case Ok(v) -> Some(value = v)\n      case Err(_) -> None\n    }\n    case None -> None\n  }"
        case None -> parsed
      }
    }
    case ChoiceParam(enumName, cases) -> {
      var chain = ""
      for name in cases {
        chain = chain + "if text == " + quoted(name) + " {\n    Some(value = " + enumName + "." + name + ")\n  } else "
      }
      chain + "{\n    None\n  }"
    }
  }
  head + body + "\n}\n"
}

func emitChoiceText(m: in Model, c: in RouteCase, f: in RouteField, enumName: in String, cases: in List[String]): String {
  var s = "func " + choiceTextName(m, c, f) + "(v: in " + enumName + "): String {\n  return match v {\n"
  for name in cases {
    s = s + "    case " + name + " -> " + quoted(name) + "\n"
  }
  s + "  }\n}\n"
}

func segmentText(m: in Model, c: in RouteCase, f: in RouteField): String {
  valueText(m, c, f, f.name)
}

// The text of the value held in variable `v`, as written to a segment or a
// query parameter.
func valueText(m: in Model, c: in RouteCase, f: in RouteField, v: in String): String {
  match f.param {
    case TextParam(distinct) -> match distinct { case Some(_) -> v + ".toString()"; case None -> v }
    case NumberParam(_, _) -> v + ".toString()"
    case ChoiceParam(_, _) -> choiceTextName(m, c, f) + "(" + v + ")"
  }
}

func queryName(f: in RouteField): String {
  match f.query {
    case Some(n) -> n
    case None -> f.name
  }
}

// `Option[Option[T]]`: `None` when the parameter is present but unusable (the
// case does not match), `Some(None)` when it is absent.  The `val`s carry the
// types, since an unannotated `None` arm is mistyped by the MSIL backend
// (#7906).
func emitQueryParse(m: in Model, c: in RouteCase, f: in RouteField): String {
  val name = quoted(queryName(f))
  "func " + queryParseName(m, c, f) + "(url: in String): Option[" + f.typeText +
    "] {\n  if not GenRouting.queryPresent(url, " +
    name +
    ") {\n    val absent: " +
    f.typeText +
    " = None\n    return Some(value = absent)\n  }\n" +
    "  val text = match GenRouting.queryValue(url, " +
    name +
    ") {\n    case Some(t) -> t\n    case None -> return None\n  }\n" +
    "  val parsed = match " +
    fieldParseName(m, c, f) +
    "(text) {\n    case Some(v) -> v\n    case None -> return None\n  }\n" +
    "  val present: " +
    f.typeText +
    " = Some(value = parsed)\n  return Some(value = present)\n}\n"
}

func emitQueryText(m: in Model, c: in RouteCase, f: in RouteField): String {
  "func " + queryTextName(m, c, f) + "(v: in " + f.typeText +
    "): Option[String] {\n  val inner = match v {\n    case Some(x) -> x\n    case None -> return None\n  }\n  return Some(value = " +
    valueText(m, c, f, "inner") +
    ")\n}\n"
}

func emitUrl(m: in Model): String {
  var s = "/// The URL of route `r`; `parse" + m.typeName + "` of it is `r`.\npub func " + m.lower + "Url(r: in " +
    m.typeName +
    "): String {\n  return match r {\n"
  for c in m.cases {
    var pattern = c.name
    if c.fields.count > 0 {
      var binds = ""
      var first = true
      for f in c.fields {
        binds = binds + (if first { "" } else { ", " }) + f.name
        first = false
      }
      pattern = c.name + "(" + binds + ")"
    }
    var url = ""
    for seg in c.segments {
      match seg {
        case Literal(t) -> {
          url = url + (if url == "" { "" } else { " + " }) + quoted("/" + t)
        }
        case Field(n, _) -> {
          var field = c.fields[0]
          for f in c.fields {
            if f.name == n {
              field = f
            }
          }
          url = url + (if url == "" { "" } else { " + " }) + quoted("/") + " + GenRouting.encodeSegment(" +
            segmentText(m, c, field) +
            ")"
        }
      }
    }
    if url == "" {
      url = quoted("/")
    }
    for f in c.fields {
      if isQuery(f) {
        url = "GenRouting.withQuery(" + url + ", " + quoted(queryName(f)) + ", " + queryTextName(m, c, f) + "(" + f.name +
          "))"
      }
    }
    s = s + "    case " + pattern + " -> " + url + "\n"
  }
  s + "  }\n}\n"
}

// ── The plugin ──────────────────────────────────────────────────────────────
@plugin(id = "lyric.ui.routes", version = "0.1.0", publisher = "lyric", implements(SourceGenerator))
pub record UiRoutesPlugin {
}

impl SourceGenerator for UiRoutesPlugin {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError] {
    Ok(value = generateSource(req))
  }
}
