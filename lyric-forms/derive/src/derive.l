//! Forms.Derive — the form generator of docs/65-ui-library-sketch.md §11
//! (D151).
//!
//! For a record or opaque type `T` annotated `@generate(Forms.Derive)` it
//! emits, in `T`'s package:
//!
//!   pub record TDraft                 each edited field's text as typed
//!   pub enum TField                   the edited fields
//!   pub func tFieldName(f): String    a field's schema name
//!   pub func tFieldNamed(n): TField?  the field with schema name `n`
//!   pub func tSchema(): FormSchema    labels, input kinds, bounds, choices
//!   pub func emptyTDraft(): TDraft    the draft of a new value
//!   pub func toTDraft(v): TDraft      the draft of an existing value
//!   pub func tDraftValue(d, f)        one field's text
//!   pub func setTField(d, f, text)    the draft with one field replaced
//!   pub func validateT(d, ...)        `T`, or every problem with the draft
//!
//! A field marked `@readonly` is not edited: it is not in the draft, and
//! `validateT` takes it as a parameter.  Each `invariant:` of `T` is
//! checked in `validateT` before `T` is constructed, and a failure is a
//! `CrossField` error carrying the invariant's `@message`.
//!
//! The generated code refers to `Forms` and `Forms.Parse` through the
//! aliases `GenForms` and `GenFormsParse`, so it never clashes with the
//! consumer's own imports.
@runtime_checked
@io
package Forms.Derive

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.GeneratorSdk

// ─── Field model ──────────────────────────────────────────────────────────────
// How an edited field is parsed, rendered and drawn.
union Shape {
  // `String`, or a distinct type over it (`Email`).
  case TextShape(distinct: Option[String])
  // `Bool`: a checkbox.
  case FlagShape
  // `Int`/`Long`, or a distinct or range type over one.  `lo`/`hi` are the
  // inclusive bounds checked while parsing; `declared` is true when the
  // type's own range is closed, so the schema advertises it.
  case NumberShape(isInt: Bool, distinct: Option[String], lo: Option[String], hi: Option[String], declared: Bool)
  // An enum declared in the same file: a select of its cases.
  case ChoiceShape(enumName: String, cases: List[EnumChoice])
  // Any type with `@form_parse(f)` and `@form_format(g)`.
  case CustomShape(typeName: String, parseFn: String, formatFn: String)
}

record EnumChoice {
  name: String
  label: String  // a Lyric string literal
}

record FormField {
  name: String
  caseName: String
  label: String  // a Lyric string literal
  optional: Bool
  shape: Shape
  typeText: String  // the field's type as written
  valueType: String  // the parsed value's type, without `Option`
  maxLength: Option[String]
  multiline: Bool
  email: Bool
  dflt: Option[String]
}

record ReadonlyField {
  name: String
  typeText: String
}

record Model {
  typeName: String
  lower: String
  fields: List[FormField]
  readonlyFields: List[ReadonlyField]
  invariants: List[InvariantDescriptor]
}

// ─── Entry point ──────────────────────────────────────────────────────────────
pub func generate(req: in GeneratorRequest): GeneratorResponse {
  val diags: List[GeneratorDiagnostic] = newList()
  val model = buildModel(req, diags)
  var failed = false
  var i = 0
  while i < diags.count {
    match diags[i].severity {
      case Error -> {
        failed = true
      }
      case _ -> ()
    }
    i += 1
  }
  if failed {
    return response("", diags)
  }
  response(emit(model), diags)
}

func response(src: in String, diags: in List[GeneratorDiagnostic]): GeneratorResponse {
  val imports: List[String] = newList()
  if src != "" {
    imports.add("import Std.Core")
    imports.add("import Std.Collections")
    imports.add("import Forms as GenForms")
    imports.add("import Forms.Parse as GenFormsParse")
  }
  GeneratorResponse(lyricSource = src, additionalImports = imports.toArray(), diagnostics = diags.toArray())
}

func report(diags: in List[GeneratorDiagnostic], code: in String, message: in String): Unit {
  diags.add(GeneratorDiagnostic(severity = Error, message = message, code = Some(value = code)))
}

// ─── Building the model ───────────────────────────────────────────────────────
func buildModel(req: in GeneratorRequest, diags: in List[GeneratorDiagnostic]): Model {
  val td = req.typeDescriptor
  val fields: List[FormField] = newList()
  val readonlyFields: List[ReadonlyField] = newList()
  val invariants: List[InvariantDescriptor] = newList()
  val model = Model(
    typeName = td.name,
    lower = lowerFirst(td.name),
    fields = fields,
    readonlyFields = readonlyFields,
    invariants = invariants
  )
  val supported = match td.kind {
    case Record -> true
    case ExposedRecord -> true
    case Opaque -> true
    case _ -> false
  }
  if not supported {
    report(diags, "FD001", "Forms.Derive derives forms for records and opaque types; '" + td.name + "' is neither")
    return model
  }
  if td.typeParams.length > 0 {
    report(diags, "FD004", "Forms.Derive cannot derive a form for the generic type '" + td.name + "'")
    return model
  }
  val reserved = reservedCaseNames(req)
  var i = 0
  while i < td.fields.length {
    val f = td.fields[i]
    if hasAnnotation(f.annotations, "readonly") {
      readonlyFields.add(ReadonlyField(name = f.name, typeText = f.fieldType.name))
    } else {
      match fieldOf(req, f, reserved, diags) {
        case Some(ff) -> fields.add(ff)
        case None -> ()
      }
    }
    i += 1
  }
  if fields.count == 0 and diags.count == 0 {
    report(diags, "FD006", "'" + td.name + "' has no field a form can edit")
  }
  var j = 0
  while j < td.invariants.length {
    invariants.add(td.invariants[j])
    j += 1
  }
  model
}

// Names a field-enum case must not take: the type itself and every type its
// fields name, which share the package's namespace with the cases.
func reservedCaseNames(req: in GeneratorRequest): List[String] {
  val acc: List[String] = newList()
  acc.add(req.typeDescriptor.name)
  acc.add(req.typeDescriptor.name + "Field")
  acc.add(req.typeDescriptor.name + "Draft")
  var i = 0
  while i < req.typeDescriptor.fields.length {
    val ft = req.typeDescriptor.fields[i].fieldType
    acc.add(ft.name)
    var k = 0
    while k < ft.typeArgs.length {
      acc.add(ft.typeArgs[k])
      k += 1
    }
    i += 1
  }
  var j = 0
  while j < req.declarations.length {
    acc.add(req.declarations[j].name)
    j += 1
  }
  acc
}

func fieldOf(
  req: in GeneratorRequest,
  f: in FieldDescriptor,
  reserved: in List[String],
  diags: in List[GeneratorDiagnostic],
): Option[FormField] {
  val optional = match f.fieldType.kind { case OptionType -> true; case _ -> false }
  val inner = if optional and f.fieldType.typeArgs.length == 1 {
    Str.trim(f.fieldType.typeArgs[0])
  } else {
    f.fieldType.name
  }
  val parseFn = annotationArg(f.annotations, "form_parse")
  val formatFn = annotationArg(f.annotations, "form_format")
  // Annotated: the MSIL backend mistypes an unannotated `None` arm here (#7906).
  val custom: Option[Shape] = match parseFn {
    case Some(p) -> match formatFn {
      case Some(g) -> Some(
        value = CustomShape(
          typeName = inner,
          parseFn = p,
          formatFn = g
        )
      )
      case None -> {
        report(diags, "FD003", "field '" + f.name + "' has @form_parse but no @form_format; a form needs both to edit it")
        return None
      }
    }
    case None -> match formatFn {
      case Some(_) -> {
        report(diags, "FD003", "field '" + f.name + "' has @form_format but no @form_parse; a form needs both to edit it")
        return None
      }
      case None -> None
    }
  }
  val shape = match custom {
    case Some(c) -> c
    case None -> match shapeOf(req, inner, 0) {
      case Some(s) -> s
      case None -> {
        report(
          diags,
          "FD002",
          "field '" + f.name + "' has type " + f.fieldType.name + ", which Forms.Derive cannot edit; " +
            "use String, Bool, Int, Long, or an enum, distinct or range type declared in this file, " +
            "or annotate the field @form_parse(f) and @form_format(g)"
        )
        return None
      }
    }
  }
  val isFlag = match shape { case FlagShape -> true; case _ -> false }
  if isFlag and optional {
    report(diags, "FD002", "field '" + f.name + "' is an optional Bool, which a checkbox cannot represent")
    return None
  }
  val maxLength = annotationArg(f.annotations, "maxLength")
  val isText = match shape { case TextShape(_) -> true; case _ -> false }
  match maxLength {
    case Some(_) -> {
      if not isText {
        report(diags, "FD005", "@maxLength on field '" + f.name + "' applies only to text fields")
        return None
      }
    }
    case None -> ()
  }
  if hasAnnotation(f.annotations, "maxLength") and not hasValue(maxLength) {
    report(diags, "FD005", "@maxLength on field '" + f.name + "' takes one argument, the maximum length")
    return None
  }
  val label = match annotationArg(f.annotations, "label") { case Some(l) -> l; case None -> literal(humanize(f.name)) }
  val cap = upperFirst(f.name)
  Some(
    value = FormField(
      name = f.name,
      caseName = if reserved.contains(cap) { cap + "Field" } else { cap },
      label = label,
      optional = optional,
      shape = shape,
      typeText = f.fieldType.name,
      valueType = inner,
      maxLength = maxLength,
      multiline = hasAnnotation(f.annotations, "multiline"),
      email = hasAnnotation(f.annotations, "email"),
      dflt = f.defaultSource
    )
  )
}

// The shape of a field whose (non-optional) type is `ty`.  `depth` bounds
// alias chains.
func shapeOf(req: in GeneratorRequest, ty: in String, depth: in Int): Option[Shape] {
  if ty == "String" {
    return Some(value = TextShape(distinct = None))
  }
  if ty == "Bool" {
    return Some(value = FlagShape)
  }
  if ty == "Int" {
    return Some(value = NumberShape(isInt = true, distinct = None, lo = None, hi = None, declared = false))
  }
  if ty == "Long" {
    return Some(value = NumberShape(isInt = false, distinct = None, lo = None, hi = None, declared = false))
  }
  if depth > 8 {
    return None
  }
  match declarationNamed(req, ty) {
    case None -> None
    case Some(d) -> match d.kind {
      case DeclaredEnum -> {
        val cases: List[EnumChoice] = newList()
        var i = 0
        while i < d.cases.length {
          val c = d.cases[i]
          val label = match annotationArg(c.annotations, "label") { case Some(l) -> l; case None -> literal(humanize(c.name)) }
          cases.add(EnumChoice(name = c.name, label = label))
          i += 1
        }
        if cases.count == 0 {
          None
        } else {
          Some(value = ChoiceShape(enumName = d.name, cases = cases))
        }
      }
      case DeclaredAlias -> match d.underlying {
        case Some(u) -> shapeOf(req, Str.trim(u), depth + 1)
        case None -> None
      }
      case DeclaredDistinct -> {
        val under = match d.underlying { case Some(u) -> Str.trim(u); case None -> "" }
        if under == "String" and not hasRange(d) {
          return Some(value = TextShape(distinct = Some(value = d.name)))
        }
        if under != "Int" and under != "Long" {
          return None
        }
        val isInt = under == "Int"
        match d.range {
          case None -> Some(
            value = NumberShape(
              isInt = isInt,
              distinct = Some(value = d.name),
              lo = None,
              hi = None,
              declared = false
            )
          )
          case Some(r) -> {
            val hi: Option[String] = match r.max {
              case Some(m) -> if r.maxInclusive {
                Some(value = m)
              } else {
                Some(value = "(" + m + ") - 1")
              }
              case None -> None
            }
            val closed = hasValue(r.min) and hasValue(hi)
            Some(value = NumberShape(isInt = isInt, distinct = Some(value = d.name), lo = r.min, hi = hi, declared = closed))
          }
        }
      }
    }
  }
}

func hasValue(o: in Option[String]): Bool {
  match o {
    case Some(_) -> true
    case None -> false
  }
}

func hasRange(d: in DeclarationDescriptor): Bool {
  match d.range {
    case Some(_) -> true
    case None -> false
  }
}

// ─── Annotations ──────────────────────────────────────────────────────────────
func hasAnnotation(anns: in slice[AnnotationDescriptor], name: in String): Bool {
  var i = 0
  while i < anns.length {
    if anns[i].name == name {
      return true
    }
    i += 1
  }
  false
}

// The single argument of annotation `name`, as source text.
func annotationArg(anns: in slice[AnnotationDescriptor], name: in String): Option[String] {
  var i = 0
  while i < anns.length {
    if anns[i].name == name and anns[i].args.length == 1 {
      return Some(value = anns[i].args[0])
    }
    i += 1
  }
  None
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

// `creditLimit` as `Credit limit`.
pub func humanize(name: in String): String {
  var acc = ""
  var i = 0
  while i < name.length {
    val c = Str.charAtOrReplacement(name, i)
    val piece = name.substring(i, 1)
    if i == 0 {
      acc = Str.toUpper(piece)
    } else if c >= 'A' and c <= 'Z' {
      acc = acc + " " + Str.toLower(piece)
    } else if c == '_' {
      acc = acc + " "
    } else {
      acc = acc + piece
    }
    i += 1
  }
  acc
}

// `s` as a Lyric string literal.
pub func literal(s: in String): String {
  var acc = "\""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c == '"' {
      acc = acc + "\\\""
    } else if c == '\\' {
      acc = acc + "\\\\"
    } else if c == '$' {
      acc = acc + "\\$"
    } else if c == '\n' {
      acc = acc + "\\n"
    } else if c == '\r' {
      acc = acc + "\\r"
    } else if c == '\t' {
      acc = acc + "\\t"
    } else {
      acc = acc + s.substring(i, 1)
    }
    i += 1
  }
  acc + "\""
}

// A name for a generated local or parameter that no field of `m` takes.
func fresh(m: in Model, base: in String): String {
  var candidate = base
  var taken = true
  while taken {
    taken = false
    for f in m.fields {
      if f.name == candidate {
        taken = true
      }
    }
    for r in m.readonlyFields {
      if r.name == candidate {
        taken = true
      }
    }
    if taken {
      candidate = candidate + "_"
    }
  }
  candidate
}

// ─── Emission ─────────────────────────────────────────────────────────────────
// Every generated declaration, in the order the module documentation lists.
func emit(m: in Model): String {
  val parts: List[String] = newList()
  parts.add(emitDraft(m))
  parts.add(emitFieldEnum(m))
  parts.add(emitFieldName(m))
  parts.add(emitFieldNamed(m))
  for f in m.fields {
    match f.shape {
      case ChoiceShape(enumName, cases) -> parts.add(emitChoiceHelpers(m, f, enumName, cases))
      case _ -> ()
    }
  }
  parts.add(emitSchema(m))
  parts.add(emitEmptyDraft(m))
  parts.add(emitToDraft(m))
  parts.add(emitDraftValue(m))
  parts.add(emitSetField(m))
  parts.add(emitValidate(m))
  Str.joinList("\n", parts)
}

func draftName(m: in Model): String {
  m.typeName + "Draft"
}

func fieldEnumName(m: in Model): String {
  m.typeName + "Field"
}

func helperName(m: in Model, f: in FormField, suffix: in String): String {
  m.lower + upperFirst(f.name) + suffix
}

func pathOf(f: in FormField): String {
  "GenForms.fieldPath(" + literal(f.name) + ")"
}

func emitDraft(m: in Model): String {
  var s = "/// The editable draft of a `" + m.typeName + "`: each field's text as typed.\npub record " + draftName(m) +
    " {\n"
  for f in m.fields {
    s = s + "  " + f.name + ": String\n"
  }
  s + "}\n"
}

func emitFieldEnum(m: in Model): String {
  var s = "/// The fields a `" + m.typeName + "` form edits.\npub enum " + fieldEnumName(m) + " {\n"
  for f in m.fields {
    s = s + "  case " + f.caseName + "\n"
  }
  s + "}\n"
}

func emitFieldName(m: in Model): String {
  var s = "/// The schema name of a field; its `FieldError`s carry `fieldPath` of it.\npub func " + m.lower +
    "FieldName(f: in " +
    fieldEnumName(m) +
    "): String {\n  return match f {\n"
  for f in m.fields {
    s = s + "    case " + f.caseName + " -> " + literal(f.name) + "\n"
  }
  s + "  }\n}\n"
}

func emitFieldNamed(m: in Model): String {
  var s = "/// The field with schema name `name`.\npub func " + m.lower + "FieldNamed(name: in String): Option[" +
    fieldEnumName(m) +
    "] {\n"
  for f in m.fields {
    s = s + "  if name == " + literal(f.name) + " {\n    return Some(value = " + fieldEnumName(m) + "." + f.caseName +
      ")\n  }\n"
  }
  s + "  return None\n}\n"
}

func emitChoiceHelpers(m: in Model, f: in FormField, enumName: in String, cases: in List[EnumChoice]): String {
  var choices = "func " + helperName(m, f, "Choices") +
    "(): List[GenForms.Choice] {\n  val cs: List[GenForms.Choice] = newList()\n"
  for c in cases {
    choices = choices + "  cs.add(GenForms.Choice(value = " + literal(c.name) + ", label = " + c.label + "))\n"
  }
  choices = choices + "  return cs\n}\n"
  var text = "func " + helperName(m, f, "Text") + "(v: in " + enumName + "): String {\n  return match v {\n"
  for c in cases {
    text = text + "    case " + c.name + " -> " + literal(c.name) + "\n"
  }
  text = text + "  }\n}\n"
  var named = "func " + helperName(m, f, "Named") + "(field: in GenForms.FieldPath, text: in String): Result[" +
    enumName +
    ", GenForms.FieldError] {\n"
  for c in cases {
    named = named + "  if text == " + literal(c.name) + " {\n    return Ok(value = " + enumName + "." + c.name +
      ")\n  }\n"
  }
  named = named +
    "  return Err(error = GenForms.Invalid(field = field, reason = \"is not one of the allowed values\"))\n}\n"
  val parse = "func " + helperName(m, f, "Parse") + "(field: in GenForms.FieldPath, raw: in String): Result[" + enumName +
    ", GenForms.FieldError] {\n  return match GenFormsParse.requiredText(field, raw) {\n    case Ok(t) -> " +
    helperName(m, f, "Named") +
    "(field, t)\n    case Err(e) -> Err(error = e)\n  }\n}\n"
  choices + "\n" + text + "\n" + named + "\n" + parse
}

func inputKind(f: in FormField): String {
  val k = match f.shape {
    case FlagShape -> "Checkbox"
    case NumberShape(_, _, _, _, _) -> "Number"
    case ChoiceShape(_, _) -> "Select"
    case _ -> if f.multiline { "MultilineText" } else if f.email { "Email" } else { "Text" }
  }
  "GenForms.InputKind." + k
}

func specExpr(m: in Model, f: in FormField): String {
  var e = "GenForms.fieldSpec(" + literal(f.name) + ", " + f.label + ", " + inputKind(f) + ")"
  val isFlag = match f.shape { case FlagShape -> true; case _ -> false }
  if not f.optional and not isFlag {
    e = "GenForms.required(" + e + ")"
  }
  match f.maxLength {
    case Some(n) -> {
      e = "GenForms.maxLength(" + e + ", " + n + ")"
    }
    case None -> ()
  }
  match f.shape {
    case NumberShape(_, _, lo, hi, declared) -> if declared {
      e = "GenForms.bounded(" + e + ", " + unwrapOr(lo, "0") + ", " + unwrapOr(hi, "0") + ")"
    }
    case ChoiceShape(_, _) -> {
      e = "GenForms.withChoices(" + e + ", " + helperName(m, f, "Choices") + "())"
    }
    case _ -> ()
  }
  e
}

func emitSchema(m: in Model): String {
  var s = "/// The form schema of a `" + m.typeName + "`.\npub func " + m.lower +
    "Schema(): GenForms.FormSchema {\n  val fs: List[GenForms.FieldSpec] = newList()\n"
  for f in m.fields {
    s = s + "  fs.add(" + specExpr(m, f) + ")\n"
  }
  s + "  return GenForms.schema(fs)\n}\n"
}

// The draft text of `v`, a value of `f`'s non-optional type.
func textOf(m: in Model, f: in FormField, v: in String): String {
  match f.shape {
    case TextShape(distinct) -> match distinct { case Some(_) -> v + ".toString()"; case None -> v }
    case FlagShape -> v + ".toString()"
    case NumberShape(_, _, _, _, _) -> v + ".toString()"
    case ChoiceShape(_, _) -> helperName(m, f, "Text") + "(" + v + ")"
    case CustomShape(_, _, fmt) -> fmt + "(" + v + ")"
  }
}

// The draft text of `v`, a value of `f`'s declared type.
func draftTextOf(m: in Model, f: in FormField, v: in String): String {
  if f.optional {
    "match " + v + " { case Some(x) -> " + textOf(m, f, "x") + "; case None -> \"\" }"
  } else {
    textOf(m, f, v)
  }
}

func emptyTextOf(m: in Model, f: in FormField): String {
  match f.dflt {
    case Some(d) -> if f.optional and Str.trim(d) == "None" { "\"\"" } else { draftTextOf(m, f, "(" + d + ")") }
    case None -> match f.shape {
      case FlagShape -> "\"false\""
      case ChoiceShape(_, cases) -> if f.optional { "\"\"" } else { literal(cases[0].name) }
      case _ -> "\"\""
    }
  }
}

func emitEmptyDraft(m: in Model): String {
  var s = "/// The draft of a new `" + m.typeName + "`: each field's default, else empty.\npub func empty" +
    draftName(m) +
    "(): " +
    draftName(m) +
    " {\n  return " +
    draftName(m) +
    "(\n"
  var i = 0
  for f in m.fields {
    s = s + "    " + f.name + " = " + emptyTextOf(m, f) + (if i < m.fields.count - 1 { ",\n" } else { "\n" })
    i += 1
  }
  s + "  )\n}\n"
}

func emitToDraft(m: in Model): String {
  val v = fresh(m, "value")
  var s = "/// The draft of an existing `" + m.typeName + "`.\npub func to" + draftName(m) + "(" + v + ": in " +
    m.typeName +
    "): " +
    draftName(m) +
    " {\n  return " +
    draftName(m) +
    "(\n"
  var i = 0
  for f in m.fields {
    s = s + "    " + f.name + " = " + draftTextOf(m, f, v + "." + f.name) +
      (if i < m.fields.count - 1 { ",\n" } else { "\n" })
    i += 1
  }
  s + "  )\n}\n"
}

func emitDraftValue(m: in Model): String {
  var s = "/// The text of field `f` in draft `d`.\npub func " + m.lower + "DraftValue(d: in " + draftName(m) +
    ", f: in " +
    fieldEnumName(m) +
    "): String {\n  return match f {\n"
  for f in m.fields {
    s = s + "    case " + f.caseName + " -> d." + f.name + "\n"
  }
  s + "  }\n}\n"
}

func emitSetField(m: in Model): String {
  var s = "/// Draft `d` with field `f` set to `text`.\npub func set" + fieldEnumName(m) + "(d: in " + draftName(m) +
    ", f: in " +
    fieldEnumName(m) +
    ", text: in String): " +
    draftName(m) +
    " {\n  return match f {\n"
  for f in m.fields {
    s = s + "    case " + f.caseName + " -> d.copy(" + f.name + " = text)\n"
  }
  s + "  }\n}\n"
}

// The parse expression of `f` from draft `d`: a `Result` of the field's
// value (an `Option` of it for an optional field) or its `FieldError`.
func parseExpr(m: in Model, f: in FormField, d: in String): String {
  val p = pathOf(f)
  val raw = d + "." + f.name
  match f.shape {
    case TextShape(_) -> textParse(f, p, raw)
    case FlagShape -> "Ok(value = GenFormsParse.flag(" + raw + "))"
    case NumberShape(isInt, _, lo, hi, _) -> {
      val low: Option[String] = match lo {
        case Some(x) -> Some(value = x)
        case None -> if isInt {
          Some(value = "-2147483648")
        } else {
          match hi {
            case Some(_) -> Some(value = "-9223372036854775807 - 1")
            case None -> None
          }
        }
      }
      val high: Option[String] = match hi {
        case Some(x) -> Some(value = x)
        case None -> if isInt {
          Some(value = "2147483647")
        } else {
          match lo {
            case Some(_) -> Some(value = "9223372036854775807")
            case None -> None
          }
        }
      }
      match low {
        case Some(a) -> {
          val b = unwrapOr(high, "0")
          if f.optional {
            "GenFormsParse.optionalLongInRange(" + p + ", " + raw + ", " + a + ", " + b + ")"
          } else {
            "GenFormsParse.longInRange(" + p + ", " + raw + ", " + a + ", " + b + ")"
          }
        }
        case None -> if f.optional {
          "GenFormsParse.optionalWholeNumber(" + p + ", " + raw + ")"
        } else {
          "GenFormsParse.wholeNumber(" + p + ", " + raw + ")"
        }
      }
    }
    case ChoiceShape(_, _) -> {
      val one = helperName(m, f, "Parse") + "(" + p + ", " + raw + ")"
      if f.optional {
        "match GenFormsParse.optionalText(" + raw + ") { case None -> Ok(value = None); case Some(_) -> match " + one +
          " { case Ok(v) -> Ok(value = Some(value = v)); case Err(e) -> Err(error = e) } }"
      } else {
        one
      }
    }
    case CustomShape(_, parseFn, _) -> {
      val conv = "match " + parseFn + "(t) { case Ok(v) -> Ok(value = " + (if f.optional { "Some(value = v)" } else { "v" }) +
        "); case Err(reason) -> Err(error = GenForms.Invalid(field = " +
        p +
        ", reason = reason)) }"
      if f.optional {
        "match GenFormsParse.optionalText(" + raw + ") { case None -> Ok(value = None); case Some(t) -> " + conv + " }"
      } else {
        "match GenFormsParse.requiredText(" + p + ", " + raw + ") { case Err(e) -> Err(error = e); case Ok(t) -> " + conv +
          " }"
      }
    }
  }
}

func textParse(f: in FormField, p: in String, raw: in String): String {
  if f.email {
    val base = if f.optional {
      "GenFormsParse.optionalEmail(" + p + ", " + raw + ")"
    } else {
      "GenFormsParse.email(" + p + ", " + raw + ")"
    }
    return match f.maxLength {
      case None -> base
      case Some(n) -> if f.optional {
        "match " + base + " { case Ok(Some(t)) -> match GenFormsParse.withinLength(" + p + ", t, " + n +
          ") { case Ok(v) -> Ok(value = Some(value = v)); case Err(e) -> Err(error = e) }; case Ok(None) -> Ok(value = None); case Err(e) -> Err(error = e) }"
      } else {
        "match " + base + " { case Ok(t) -> GenFormsParse.withinLength(" + p + ", t, " + n +
          "); case Err(e) -> Err(error = e) }"
      }
    }
  }
  match f.maxLength {
    case Some(n) -> if f.optional {
      "GenFormsParse.optionalTextUpTo(" + p + ", " + raw + ", " + n + ")"
    } else {
      "GenFormsParse.requiredTextUpTo(" + p + ", " + raw + ", " + n + ")"
    }
    case None -> if f.optional {
      "Ok(value = GenFormsParse.optionalText(" + raw + "))"
    } else {
      "GenFormsParse.requiredText(" + p + ", " + raw + ")"
    }
  }
}

// The type `parseExpr` yields a value of.
func parsedType(f: in FormField): String {
  val one = match f.shape {
    case TextShape(_) -> "String"
    case FlagShape -> "Bool"
    case NumberShape(_, _, _, _, _) -> "Long"
    case ChoiceShape(enumName, _) -> enumName
    case CustomShape(typeName, _, _) -> typeName
  }
  if f.optional {
    "Option[" + one + "]"
  } else {
    one
  }
}

// `v`, a parsed value of `f`'s non-optional type, converted to the field's
// type.  A range was checked while parsing, so `from` cannot fail.
func convertOne(f: in FormField, v: in String): String {
  match f.shape {
    case TextShape(distinct) -> match distinct { case Some(t) -> t + ".from(" + v + ")"; case None -> v }
    case NumberShape(isInt, distinct, _, _, _) -> {
      val n = if isInt { v + ".toInt()" } else { v }
      match distinct {
        case Some(t) -> t + ".from(" + n + ")"
        case None -> n
      }
    }
    case _ -> v
  }
}

func converted(f: in FormField, v: in String): String {
  val same = convertOne(f, "x") == "x"
  if same {
    v
  } else if f.optional {
    "match " + v + " { case Some(x) -> Some(value = " + convertOne(f, "x") + "); case None -> None }"
  } else {
    convertOne(f, v)
  }
}

func emitValidate(m: in Model): String {
  val d = fresh(m, "d")
  val errs = fresh(m, "errs")
  var params = d + ": in " + draftName(m)
  for r in m.readonlyFields {
    params = params + ", " + r.name + ": in " + r.typeText
  }
  var s = "/// The `" + m.typeName + "` draft `" + d + "` describes, or every problem with it.\npub func validate" +
    m.typeName +
    "(" +
    params +
    "): Result[" +
    m.typeName +
    ", List[GenForms.FieldError]] {\n  val " +
    errs +
    ": List[GenForms.FieldError] = newList()\n"
  for f in m.fields {
    val r = fresh(m, f.name + "Parsed")
    s = s + "  val " + r + ": Result[" + parsedType(f) + ", GenForms.FieldError] = " + parseExpr(m, f, d) + "\n"
    s = s + "  GenFormsParse.noteError(" + errs + ", " + r + ")\n"
  }
  s = s + "  if " + errs + ".count > 0 {\n    return Err(error = " + errs + ")\n  }\n"
  for f in m.fields {
    val r = fresh(m, f.name + "Parsed")
    s = s + "  val " + f.name + ": " + f.typeText + " = match " + r + " { case Ok(v) -> " + converted(f, "v") +
      "; case Err(_) -> return Err(error = " +
      errs +
      ") }\n"
  }
  for inv in m.invariants {
    val message = match inv.message {
      case Some(text) -> literal(text)
      case None -> literal(m.typeName + ": " + inv.source + " does not hold")
    }
    s = s + "  if not (" + inv.source + ") {\n    " + errs + ".add(GenForms.CrossField(message = " + message + "))\n  }\n"
  }
  if m.invariants.count > 0 {
    s = s + "  if " + errs + ".count > 0 {\n    return Err(error = " + errs + ")\n  }\n"
  }
  var args = ""
  var first = true
  for r in m.readonlyFields {
    args = args + (if first { "" } else { ", " }) + r.name + " = " + r.name
    first = false
  }
  for f in m.fields {
    args = args + (if first { "" } else { ", " }) + f.name + " = " + f.name
    first = false
  }
  s + "  return Ok(value = " + m.typeName + "(" + args + "))\n}\n"
}

func main(): Int {
  runGenerator(generate)
}
