//! tests/derive_tests.l — unit tests for the Forms.Derive generator.  The
//! generated code itself is compiled and run by examples/ui-customers, whose
//! domain type is derived with it.
@test_module
package Forms.DeriveTests

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.GeneratorSdk
import Forms.Derive

func field(
  name: in String,
  ty: in String,
  kind: in FieldTypeKind,
  args: in slice[String],
  anns: in slice[AnnotationDescriptor],
): FieldDescriptor {
  FieldDescriptor(
    name = name,
    fieldType = FieldType(kind = kind, name = ty, typeArgs = args),
    isPublic = true,
    annotations = anns
  )
}

func ann(name: in String, args: in slice[String]): AnnotationDescriptor {
  AnnotationDescriptor(name = name, args = args)
}

func request(
  kind: in ItemKind,
  fields: in slice[FieldDescriptor],
  decls: in slice[DeclarationDescriptor],
  invs: in slice[InvariantDescriptor],
): GeneratorRequest {
  val td = TypeDescriptor(
    kind = kind,
    name = "Customer",
    packageName = "Domain",
    typeParams = [],
    fields = fields,
    annotations = [],
    invariants = invs
  )
  GeneratorRequest(
    generatorArg = "Forms.Derive",
    typeDescriptor = td,
    packageName = "Domain",
    sourceFile = "d.l",
    declarations = decls
  )
}

func tierDecl(): DeclarationDescriptor {
  DeclarationDescriptor(
    name = "Tier",
    kind = DeclaredEnum,
    underlying = None,
    range = None,
    cases = [
      CaseDescriptor(name = "Standard", annotations = [], fields = []),
      CaseDescriptor(name = "Key", annotations = [ann("label", ["\"Key account\""])], fields = [])
    ]
  )
}

func limitDecl(): DeclarationDescriptor {
  DeclarationDescriptor(
    name = "CreditLimit",
    kind = DeclaredDistinct,
    underlying = Some(value = "Long"),
    range = Some(value = RangeDescriptor(min = Some(value = "0"), max = Some(value = "1_000_000"), maxInclusive = true)),
    cases = []
  )
}

func customer(): GeneratorRequest {
  request(
    Record,
    [
      field("id", "CustomerId", Named, [], [ann("readonly", [])]),
      field("name", "String", Primitive, [], [ann("maxLength", ["100"])]),
      field("email", "String", Primitive, [], [ann("email", [])]),
      field("creditLimit", "CreditLimit", Named, [], []),
      field("tier", "Tier", Named, [], []),
      field("notes", "String?", OptionType, ["String"], [ann("multiline", []), ann("maxLength", ["2000"])])
    ],
    [tierDecl(), limitDecl()],
    [
      InvariantDescriptor(
        source = "keyAccountLimitOk(tier, creditLimit)",
        message = Some(value = "Key accounts need \"10000\""),
        line = 9,
        column = 3
      )
    ]
  )
}

func errorCodes(r: in GeneratorResponse): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < r.diagnostics.length {
    match r.diagnostics[i].code {
      case Some(c) -> acc.add(c)
      case None -> ()
    }
    i += 1
  }
  acc
}

test "a customer form: draft, field enum, schema and validate" {
  val r = generate(customer())
  assertEqualInt(r.diagnostics.length, 0, "no diagnostics")
  val src = r.lyricSource
  assertTrue(
    src.contains(
      "pub record CustomerDraft {\n  name: String\n  email: String\n  creditLimit: String\n  tier: String\n  notes: String\n}"
    ),
    "draft: " + src
  )
  assertTrue(
    src.contains(
      "pub enum CustomerField {\n  case Name\n  case Email\n  case CreditLimitField\n  case TierField\n  case Notes\n}"
    ),
    "a case named like a type takes a Field suffix"
  )
  assertTrue(
    src.contains(
      "GenForms.maxLength(GenForms.required(GenForms.fieldSpec(\"name\", \"Name\", GenForms.InputKind.Text)), 100)"
    ),
    "name spec"
  )
  assertTrue(
    src.contains("GenForms.required(GenForms.fieldSpec(\"email\", \"Email\", GenForms.InputKind.Email))"),
    "email spec"
  )
  assertTrue(
    src.contains(
      "GenForms.bounded(GenForms.required(GenForms.fieldSpec(\"creditLimit\", \"Credit limit\", GenForms.InputKind.Number)), 0, 1_000_000)"
    ),
    "range bounds"
  )
  assertTrue(
    src.contains(
      "GenForms.withChoices(GenForms.required(GenForms.fieldSpec(\"tier\", \"Tier\", GenForms.InputKind.Select)), customerTierChoices())"
    ),
    "select"
  )
  assertTrue(src.contains("GenForms.Choice(value = \"Key\", label = \"Key account\")"), "a case's @label")
  assertTrue(
    src.contains("GenForms.maxLength(GenForms.fieldSpec(\"notes\", \"Notes\", GenForms.InputKind.MultilineText), 2000)"),
    "optional multiline"
  )
  assertTrue(
    src.contains(
      "pub func validateCustomer(d: in CustomerDraft, id: in CustomerId): Result[Customer, List[GenForms.FieldError]]"
    ),
    "validate takes the read-only field"
  )
  assertTrue(
    src.contains("GenFormsParse.longInRange(GenForms.fieldPath(\"creditLimit\"), d.creditLimit, 0, 1_000_000)"),
    "range parse"
  )
  assertTrue(src.contains("case Ok(v) -> CreditLimit.from(v)"), "range conversion")
  assertTrue(
    src.contains(
      "if not (keyAccountLimitOk(tier, creditLimit)) {\n    errs.add(GenForms.CrossField(message = \"Key accounts need \\\"10000\\\"\"))"
    ),
    "invariant with its message"
  )
  assertTrue(
    src.contains(
      "return Ok(value = Customer(id = id, name = name, email = email, creditLimit = creditLimit, tier = tier, notes = notes))"
    ),
    "construction"
  )
  assertTrue(src.contains("case Notes -> d.copy(notes = text)"), "set field")
  assertEqualInt(r.additionalImports.length, 4, "Std.Core, Std.Collections, Forms and Forms.Parse")
}

test "an invariant without @message is reported by its source" {
  val req = request(
    Record,
    [field("count", "Int", Primitive, [], [])],
    [],
    [InvariantDescriptor(source = "count > 0", message = None, line = 3, column = 3)]
  )
  val src = generate(req).lyricSource
  assertTrue(
    src.contains("GenForms.CrossField(message = \"Customer: count > 0 does not hold\")"),
    "default message: " + src
  )
  assertTrue(
    src.contains("GenFormsParse.longInRange(GenForms.fieldPath(\"count\"), d.count, -2147483648, 2147483647)"),
    "an Int is checked to fit"
  )
  assertTrue(src.contains("case Ok(v) -> v.toInt()"), "and narrowed")
}

test "a field named like a generated local gets a fresh local" {
  val req = request(Record, [field("d", "String", Primitive, [], []), field("errs", "Bool", Primitive, [], [])], [], [])
  val src = generate(req).lyricSource
  assertTrue(src.contains("pub func validateCustomer(d_: in CustomerDraft)"), "draft parameter renamed: " + src)
  assertTrue(src.contains("val errs_: List[GenForms.FieldError] = newList()"), "error list renamed")
  assertTrue(src.contains("GenFormsParse.flag(d_.errs)"), "a Bool is a checkbox flag")
}

test "a union, a generic type and an unsupported field are refused" {
  assertTrue(errorCodes(generate(request(Union, [], [], []))).contains("FD001"), "FD001 for a union")
  val boxed = GeneratorRequest(
    generatorArg = "Forms.Derive",
    typeDescriptor = TypeDescriptor(
      kind = Record,
      name = "Box",
      packageName = "P",
      typeParams = ["T"],
      fields = [],
      annotations = []
    ),
    packageName = "P",
    sourceFile = "p.l"
  )
  assertTrue(errorCodes(generate(boxed)).contains("FD004"), "FD004 for a generic type")
  val r = generate(request(Record, [field("lines", "List[Line]", Generic, ["Line"], [])], [], []))
  assertTrue(errorCodes(r).contains("FD002"), "FD002 for a list field")
  assertEqual(r.lyricSource, "", "no code when an error is reported")
  assertEqualInt(r.additionalImports.length, 0, "and no imports")
}

test "@form_parse needs @form_format, and together they edit any type" {
  val half = request(Record, [field("at", "Instant", Named, [], [ann("form_parse", ["parseInstant"])])], [], [])
  assertTrue(errorCodes(generate(half)).contains("FD003"), "FD003 without @form_format")
  val both = request(
    Record,
    [
      field(
        "at",
        "Instant",
        Named,
        [],
        [ann("form_parse", ["parseInstant"]), ann("form_format", ["formatInstant"])]
      )
    ],
    [],
    []
  )
  val r = generate(both)
  assertEqualInt(r.diagnostics.length, 0, "accepted")
  assertTrue(
    r.lyricSource.contains(
      "match parseInstant(t) { case Ok(v) -> Ok(value = v); case Err(reason) -> Err(error = GenForms.Invalid(field = GenForms.fieldPath(\"at\"), reason = reason)) }"
    ),
    "parse call: " + r.lyricSource
  )
  assertTrue(r.lyricSource.contains("at = formatInstant(value.at)"), "format call")
}

test "@maxLength applies only to text" {
  val r = generate(request(Record, [field("n", "Long", Primitive, [], [ann("maxLength", ["5"])])], [], []))
  assertTrue(errorCodes(r).contains("FD005"), "FD005")
}

test "names and literals" {
  assertEqual(humanize("creditLimit"), "Credit limit", "camel case")
  assertEqual(humanize("first_name"), "First name", "snake case")
  assertEqual(literal("a \"b\" \\ \${c}"), "\"a \\\"b\\\" \\\\ \\\${c}\"", "escapes")
}
