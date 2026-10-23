//! generator_sdk_tests.l — @test_module for Lyric.GeneratorSdk
//!
//! Test suite for the generator SDK: the descriptor and response types, the
//! codecs `Lyric.PluginExpand` generates for them (the JSON the compiler and
//! a generator exchange), and `projectPathWithin`.
@test_module
package Lyric.GeneratorSdk.Tests

import Std.Core
import Std.Testing
import Std.Collections
import Std.JsonValue as Jv
import Lyric.GeneratorSdk

// ─────────────────────────────────────────────────────────────────────────────
// Helpers: the request as the JSON text the compiler sends.
// ─────────────────────────────────────────────────────────────────────────────
func encodeText(req: in GeneratorRequest): String {
  Jv.writeValue(pluginEncodeGeneratorRequest(req))
}

func decodeText(json: in String): Result[GeneratorRequest, String] {
  match Jv.parseValue(json) {
    case Ok(v) -> pluginDecodeGeneratorRequest(v)
    case Err(e) -> Err(error = e.message())
  }
}

func roundTrip(req: in GeneratorRequest): Result[GeneratorRequest, String] {
  decodeText(encodeText(req))
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. AnnotationDescriptor — annotation values
// ─────────────────────────────────────────────────────────────────────────────
test "AnnotationDescriptor: name and empty args" {
  val ann = AnnotationDescriptor(name = "required", args = [])
  assertTrue(ann.name == "required", "name field")
  assertTrue(ann.args.toArray().count == 0, "empty args array")
}

test "AnnotationDescriptor: name with multiple args" {
  val ann = AnnotationDescriptor(name = "since", args = ["\"1.0\"", "\"Json\""])
  assertTrue(ann.name == "since", "name field")
  assertTrue(ann.args.toArray().count == 2, "two args")
  val argArr = ann.args.toArray()
  assertTrue(argArr[0] == "\"1.0\"", "first arg")
  assertTrue(argArr[1] == "\"Json\"", "second arg")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. FieldTypeKind — field type categorization
// ─────────────────────────────────────────────────────────────────────────────
test "FieldTypeKind.Primitive: can be matched" {
  val kind = Primitive
  val matched = match kind { case Primitive -> true; case _ -> false }
  assertTrue(matched, "Primitive variant")
}

test "FieldTypeKind.Slice: can be matched" {
  val kind = Slice
  val matched = match kind { case Slice -> true; case _ -> false }
  assertTrue(matched, "Slice variant")
}

test "FieldTypeKind.OptionType: can be matched" {
  val kind = OptionType
  val matched = match kind { case OptionType -> true; case _ -> false }
  assertTrue(matched, "OptionType variant")
}

test "FieldTypeKind.ResultType: can be matched" {
  val kind = ResultType
  val matched = match kind { case ResultType -> true; case _ -> false }
  assertTrue(matched, "ResultType variant")
}

test "FieldTypeKind.Named: can be matched" {
  val kind = Named
  val matched = match kind { case Named -> true; case _ -> false }
  assertTrue(matched, "Named variant")
}

test "FieldTypeKind.Generic: can be matched" {
  val kind = Generic
  val matched = match kind { case Generic -> true; case _ -> false }
  assertTrue(matched, "Generic variant")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. FieldType — resolved type information
// ─────────────────────────────────────────────────────────────────────────────
test "FieldType: primitive Int" {
  val ft = FieldType(kind = Primitive, name = "Int", typeArgs = [])
  assertTrue(ft.name == "Int", "name field")
  assertTrue(ft.typeArgs.toArray().count == 0, "no type args")
}

test "FieldType: slice with String element" {
  val ft = FieldType(kind = Slice, name = "slice[String]", typeArgs = ["String"])
  assertTrue(ft.name == "slice[String]", "name includes brackets")
  assertTrue(ft.typeArgs.toArray().count == 1, "one type arg")
  assertTrue(ft.typeArgs.toArray()[0] == "String", "element type")
}

test "FieldType: Option with String" {
  val ft = FieldType(kind = OptionType, name = "Option[String]", typeArgs = ["String"])
  assertTrue(ft.kind == OptionType, "kind")
  assertTrue(ft.typeArgs.toArray()[0] == "String", "inner type")
}

test "FieldType: Result with two type args" {
  val ft = FieldType(kind = ResultType, name = "Result[Int, String]", typeArgs = ["Int", "String"])
  val args = ft.typeArgs.toArray()
  assertTrue(args.count == 2, "two type args")
  assertTrue(args[0] == "Int", "success type")
  assertTrue(args[1] == "String", "error type")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. FieldDescriptor — field information
// ─────────────────────────────────────────────────────────────────────────────
test "FieldDescriptor: simple public field" {
  val fd = FieldDescriptor(
    name = "id",
    fieldType = FieldType(kind = Primitive, name = "Int", typeArgs = []),
    isPublic = true,
    annotations = []
  )
  assertTrue(fd.name == "id", "name")
  assertTrue(fd.isPublic, "public")
  assertTrue(fd.annotations.toArray().count == 0, "no annotations")
}

test "FieldDescriptor: private field" {
  val fd = FieldDescriptor(
    name = "_internal",
    fieldType = FieldType(kind = Primitive, name = "String", typeArgs = []),
    isPublic = false,
    annotations = []
  )
  assertTrue(fd.isPublic == false, "private field")
}

test "FieldDescriptor: field with annotation" {
  val ann = AnnotationDescriptor(name = "required", args = [])
  val fd = FieldDescriptor(
    name = "email",
    fieldType = FieldType(kind = Primitive, name = "String", typeArgs = []),
    isPublic = true,
    annotations = [ann]
  )
  assertTrue(fd.annotations.toArray().count == 1, "one annotation")
  assertTrue(fd.annotations.toArray()[0].name == "required", "annotation name")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. ItemKind — type declaration kinds
// ─────────────────────────────────────────────────────────────────────────────
test "ItemKind.Record: can be matched" {
  val kind = Record
  val matched = match kind { case Record -> true; case _ -> false }
  assertTrue(matched, "Record variant")
}

test "ItemKind.ExposedRecord: can be matched" {
  val kind = ExposedRecord
  val matched = match kind { case ExposedRecord -> true; case _ -> false }
  assertTrue(matched, "ExposedRecord variant")
}

test "ItemKind.Union: can be matched" {
  val kind = Union
  val matched = match kind { case Union -> true; case _ -> false }
  assertTrue(matched, "Union variant")
}

test "ItemKind.Interface: can be matched" {
  val kind = Interface
  val matched = match kind { case Interface -> true; case _ -> false }
  assertTrue(matched, "Interface variant")
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. TypeDescriptor — full type information
// ─────────────────────────────────────────────────────────────────────────────
test "TypeDescriptor: simple record" {
  val td = TypeDescriptor(
    kind = Record,
    name = "User",
    packageName = "MyApp.Models",
    typeParams = [],
    fields = [],
    annotations = []
  )
  assertTrue(td.name == "User", "name")
  assertTrue(td.packageName == "MyApp.Models", "package")
  assertTrue(td.kind == Record, "kind")
}

test "TypeDescriptor: generic type" {
  val td = TypeDescriptor(
    kind = Record,
    name = "Container",
    packageName = "Std",
    typeParams = ["T", "E"],
    fields = [],
    annotations = []
  )
  val params = td.typeParams.toArray()
  assertTrue(params.count == 2, "two type parameters")
  assertTrue(params[0] == "T", "first param")
  assertTrue(params[1] == "E", "second param")
}

test "TypeDescriptor: with fields" {
  val fields = [
    FieldDescriptor(
      name = "id",
      fieldType = FieldType(kind = Primitive, name = "Int", typeArgs = []),
      isPublic = true,
      annotations = []
    ),
    FieldDescriptor(
      name = "name",
      fieldType = FieldType(kind = Primitive, name = "String", typeArgs = []),
      isPublic = true,
      annotations = []
    )
  ]
  val td = TypeDescriptor(
    kind = Record,
    name = "User",
    packageName = "Models",
    typeParams = [],
    fields = fields,
    annotations = []
  )
  val fds = td.fields.toArray()
  assertTrue(fds.count == 2, "two fields")
  assertTrue(fds[0].name == "id", "first field")
  assertTrue(fds[1].name == "name", "second field")
}

test "TypeDescriptor: with annotations" {
  val ann = AnnotationDescriptor(name = "derive", args = ["Eq"])
  val td = TypeDescriptor(
    kind = Record,
    name = "Point",
    packageName = "Geometry",
    typeParams = [],
    fields = [],
    annotations = [ann]
  )
  assertTrue(td.annotations.toArray().count == 1, "one annotation")
}

test "TypeDescriptor: union type" {
  val td = TypeDescriptor(
    kind = Union,
    name = "Result",
    packageName = "Std",
    typeParams = ["T", "E"],
    fields = [],
    annotations = []
  )
  assertTrue(td.kind == Union, "kind is Union")
}

test "TypeDescriptor: interface" {
  val td = TypeDescriptor(
    kind = Interface,
    name = "Reader",
    packageName = "Io",
    typeParams = ["T"],
    fields = [],
    annotations = []
  )
  assertTrue(td.kind == Interface, "kind is Interface")
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. GeneratorRequest — request contract
// ─────────────────────────────────────────────────────────────────────────────
test "GeneratorRequest: basic fields" {
  val td = TypeDescriptor(
    kind = Record,
    name = "Order",
    packageName = "MyApp.Models",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Proto.Derive",
    typeDescriptor = td,
    packageName = "MyApp",
    sourceFile = "order.l"
  )
  assertTrue(req.generatorArg == "Proto.Derive", "generator arg")
  assertTrue(req.typeDescriptor.name == "Order", "type descriptor")
  assertTrue(req.packageName == "MyApp", "package name")
  assertTrue(req.sourceFile == "order.l", "source file")
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. The generated request codec
// ─────────────────────────────────────────────────────────────────────────────
test "encode: minimal request" {
  val td = TypeDescriptor(
    kind = Record,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Pkg", sourceFile = "f.l")
  val json = encodeText(req)
  assertTrue(json.contains("\"generatorArg\":\"Gen\""), "generator arg")
  assertTrue(json.contains("\"name\":\"Type\""), "type name")
  assertTrue(json.contains("\"packageName\":\"Pkg\""), "package name")
  assertTrue(json.contains("\"sourceFile\":\"f.l\""), "source file")
}

test "encode: request with special characters" {
  val td = TypeDescriptor(
    kind = Record,
    name = "Type\"Quote",
    packageName = "App\\Path",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "App",
    sourceFile = "path\\file.l"
  )
  val json = encodeText(req)
  assertTrue(json.contains("\\\""), "quote escaped")
  assertTrue(json.contains("\\\\"), "backslash escaped")
}

test "encode: request with type parameters" {
  val td = TypeDescriptor(
    kind = Record,
    name = "Container",
    packageName = "Std",
    typeParams = ["T", "E"],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Std", sourceFile = "c.l")
  val json = encodeText(req)
  assertTrue(json.contains("[\"T\",\"E\"]"), "type params serialized")
}

test "encode: request with fields" {
  val fields = [
    FieldDescriptor(
      name = "id",
      fieldType = FieldType(kind = Primitive, name = "Int", typeArgs = []),
      isPublic = true,
      annotations = []
    )
  ]
  val td = TypeDescriptor(
    kind = Record,
    name = "User",
    packageName = "Models",
    typeParams = [],
    fields = fields,
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Proto", typeDescriptor = td, packageName = "Models", sourceFile = "user.l")
  val json = encodeText(req)
  assertTrue(json.contains("\"name\":\"id\""), "field name")
  assertTrue(json.contains("\"Primitive\""), "field type kind")
}

// The generated decoder is the inverse of the generated encoder: type
// parameters, fields and field type arguments round-trip.
test "codec: round-trips type parameters and fields" {
  val fields = [
    FieldDescriptor(
      name = "id",
      fieldType = FieldType(kind = Primitive, name = "Int", typeArgs = []),
      isPublic = true,
      annotations = []
    ),
    FieldDescriptor(
      name = "tags",
      fieldType = FieldType(kind = Generic, name = "Map", typeArgs = ["String", "T"]),
      isPublic = true,
      annotations = []
    )
  ]
  val td = TypeDescriptor(
    kind = Union,
    name = "Tagged",
    packageName = "Models",
    typeParams = ["T"],
    fields = fields,
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Proto.Derive",
    typeDescriptor = td,
    packageName = "Models",
    sourceFile = "m.l"
  )
  match roundTrip(req) {
    case Err(msg) -> assertTrue(false, "round trip failed: " + msg)
    case Ok(back) -> {
      assertEqual(back.generatorArg, "Proto.Derive", "generatorArg")
      assertEqual(back.packageName, "Models", "packageName")
      assertEqual(back.sourceFile, "m.l", "sourceFile")
      assertEqual(back.typeDescriptor.name, "Tagged", "type name")
      assertTrue(match back.typeDescriptor.kind { case Union -> true; case _ -> false }, "kind")
      assertEqualInt(back.typeDescriptor.typeParams.length, 1, "type param count")
      assertEqual(back.typeDescriptor.typeParams[0], "T", "type param")
      assertEqualInt(back.typeDescriptor.fields.length, 2, "field count")
      assertEqual(back.typeDescriptor.fields[1].name, "tags", "second field name")
      assertEqualInt(back.typeDescriptor.fields[1].fieldType.typeArgs.length, 2, "field type arg count")
      assertEqual(back.typeDescriptor.fields[1].fieldType.typeArgs[1], "T", "field type arg")
    }
  }
}

test "encode: ExposedRecord variant" {
  val td = TypeDescriptor(
    kind = ExposedRecord,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Pkg", sourceFile = "f.l")
  val json = encodeText(req)
  assertTrue(json.contains("ExposedRecord"), "ItemKind ExposedRecord serialized")
}

test "encode: Union variant" {
  val td = TypeDescriptor(
    kind = Union,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Pkg", sourceFile = "f.l")
  val json = encodeText(req)
  assertTrue(json.contains("Union"), "ItemKind Union serialized")
}

test "encode: Interface variant" {
  val td = TypeDescriptor(
    kind = Interface,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Pkg", sourceFile = "f.l")
  val json = encodeText(req)
  assertTrue(json.contains("Interface"), "ItemKind Interface serialized")
}

test "encode: Slice field type" {
  val ft = FieldType(kind = Slice, name = "T", typeArgs = [])
  val fd = FieldDescriptor(name = "f", fieldType = ft, isPublic = true, annotations = [])
  val td = TypeDescriptor(
    kind = Record,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [fd],
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Pkg", sourceFile = "f.l")
  val json = encodeText(req)
  assertTrue(json.contains("Slice"), "FieldTypeKind Slice in JSON")
}

test "encode: Generic field type" {
  val ft = FieldType(kind = Generic, name = "T", typeArgs = [])
  val fd = FieldDescriptor(name = "f", fieldType = ft, isPublic = true, annotations = [])
  val td = TypeDescriptor(
    kind = Record,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [fd],
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Pkg", sourceFile = "f.l")
  val json = encodeText(req)
  assertTrue(json.contains("Generic"), "FieldTypeKind Generic in JSON")
}

test "encode: field with annotations" {
  val ann = AnnotationDescriptor(name = "required", args = [])
  val ft = FieldType(kind = Primitive, name = "String", typeArgs = [])
  val fd = FieldDescriptor(name = "email", fieldType = ft, isPublic = true, annotations = [ann])
  val td = TypeDescriptor(
    kind = Record,
    name = "User",
    packageName = "Pkg",
    typeParams = [],
    fields = [fd],
    annotations = []
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Pkg", sourceFile = "f.l")
  val json = encodeText(req)
  assertTrue(json.contains("\"name\":\"required\""), "annotation name in JSON")
}

test "encode: annotation with arguments" {
  val ann = AnnotationDescriptor(name = "since", args = ["\"1.0\""])
  val td = TypeDescriptor(
    kind = Record,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = [ann]
  )
  val req = GeneratorRequest(generatorArg = "Gen", typeDescriptor = td, packageName = "Pkg", sourceFile = "f.l")
  val json = encodeText(req)
  assertTrue(json.contains("\"args\":[\"\\\"1.0\\\"\"]"), "annotation args serialized")
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. GeneratorDiagnosticSeverity — diagnostic levels
// ─────────────────────────────────────────────────────────────────────────────
test "GeneratorDiagnosticSeverity.Error: can be matched" {
  val sev = Error
  val matched = match sev { case Error -> true; case _ -> false }
  assertTrue(matched, "Error variant")
}

test "GeneratorDiagnosticSeverity.Warning: can be matched" {
  val sev = Warning
  val matched = match sev { case Warning -> true; case _ -> false }
  assertTrue(matched, "Warning variant")
}

test "GeneratorDiagnosticSeverity.Info: can be matched" {
  val sev = Info
  val matched = match sev { case Info -> true; case _ -> false }
  assertTrue(matched, "Info variant")
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. GeneratorDiagnostic — diagnostic messages
// ─────────────────────────────────────────────────────────────────────────────
test "GeneratorDiagnostic: error with code" {
  val diag = GeneratorDiagnostic(severity = Error, message = "Invalid type", code = Some(value = "G001"))
  assertTrue(diag.severity == Error, "severity")
  assertTrue(diag.message == "Invalid type", "message")
  val hasCode = match diag.code { case Some(_) -> true; case None -> false }
  assertTrue(hasCode, "has code")
}

test "GeneratorDiagnostic: warning without code" {
  val diag = GeneratorDiagnostic(severity = Warning, message = "Unused type param", code = None)
  assertTrue(diag.severity == Warning, "severity")
  val hasCode = match diag.code { case Some(_) -> true; case None -> false }
  assertFalse(hasCode, "no code")
}

test "GeneratorDiagnostic: info with empty code string" {
  val diag = GeneratorDiagnostic(severity = Info, message = "Processing started", code = Some(value = ""))
  assertTrue(diag.severity == Info, "severity")
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. GeneratorResponse — response contract
// ─────────────────────────────────────────────────────────────────────────────
test "GeneratorResponse: basic response" {
  val resp = GeneratorResponse(lyricSource = "pub func generated(): Unit {}", additionalImports = [], diagnostics = [])
  assertTrue(resp.lyricSource == "pub func generated(): Unit {}", "source")
  assertTrue(resp.additionalImports.toArray().count == 0, "no imports")
  assertTrue(resp.diagnostics.toArray().count == 0, "no diagnostics")
}

test "GeneratorResponse: with imports" {
  val resp = GeneratorResponse(
    lyricSource = "",
    additionalImports = ["import Std.Json", "import Std.Collections"],
    diagnostics = []
  )
  val imports = resp.additionalImports.toArray()
  assertTrue(imports.count == 2, "two imports")
  assertTrue(imports[0] == "import Std.Json", "first import")
}

test "GeneratorResponse: with diagnostics" {
  val diag1 = GeneratorDiagnostic(severity = Error, message = "Error 1", code = None)
  val diag2 = GeneratorDiagnostic(severity = Warning, message = "Warning 1", code = Some(value = "W001"))
  val resp = GeneratorResponse(lyricSource = "", additionalImports = [], diagnostics = [diag1, diag2])
  val diags = resp.diagnostics.toArray()
  assertTrue(diags.count == 2, "two diagnostics")
  assertTrue(diags[0].severity == Error, "first is error")
  val hasCode = match diags[1].code { case Some(_) -> true; case None -> false }
  assertTrue(hasCode, "second has code")
}

// ─────────────────────────────────────────────────────────────────────────────
// §13. Round-trip compatibility
// ─────────────────────────────────────────────────────────────────────────────
test "Round-trip: request with complex types" {
  val fields = [
    FieldDescriptor(
      name = "items",
      fieldType = FieldType(kind = Slice, name = "slice[String]", typeArgs = ["String"]),
      isPublic = true,
      annotations = [AnnotationDescriptor(name = "required", args = [])]
    ),
    FieldDescriptor(
      name = "result",
      fieldType = FieldType(kind = ResultType, name = "Result[Int, String]", typeArgs = ["Int", "String"]),
      isPublic = true,
      annotations = []
    )
  ]
  val td = TypeDescriptor(
    kind = Record,
    name = "ComplexType",
    packageName = "MyApp.Models",
    typeParams = ["T"],
    fields = fields,
    annotations = [AnnotationDescriptor(name = "derive", args = ["Eq"])]
  )
  val req = GeneratorRequest(
    generatorArg = "Proto.Derive",
    typeDescriptor = td,
    packageName = "MyApp",
    sourceFile = "complex.l"
  )
  val json = encodeText(req)
  assertTrue(json.contains("ComplexType"), "type name present")
  assertTrue(json.contains("Slice"), "field kind present")
  assertTrue(json.contains("ResultType"), "result type present")
  assertTrue(json.contains("\"required\""), "annotation present")
}

// ─────────────────────────────────────────────────────────────────────────────
// §19. TypeDescriptor invariant (#7255)
// ─────────────────────────────────────────────────────────────────────────────
func constructTypeDescriptorWithEmptyName(): Unit {
  val td = TypeDescriptor(
    kind = Record,
    name = "",
    packageName = "MyApp",
    typeParams = [],
    fields = [],
    annotations = []
  )
}

test "TypeDescriptor: invariant panics on an empty name" {
  assertPanics("TypeDescriptor(name = \"\")", constructTypeDescriptorWithEmptyName)
}

// ─────────────────────────────────────────────────────────────────────────────
// Schema 2: cases, invariants, field defaults, opaque types and enums
// ─────────────────────────────────────────────────────────────────────────────
test "codec: a schema 2 union round-trips its cases and their annotations" {
  val idField = FieldDescriptor(
    name = "id",
    fieldType = FieldType(kind = Named, name = "CustomerId", typeArgs = []),
    isPublic = true,
    annotations = []
  )
  val td = TypeDescriptor(
    kind = Union,
    name = "Route",
    packageName = "App",
    typeParams = [],
    fields = [],
    annotations = [],
    cases = [
      CaseDescriptor(
        name = "CustomerList",
        annotations = [AnnotationDescriptor(name = "path", args = ["\"/customers\""])],
        fields = []
      ),
      CaseDescriptor(
        name = "EditCustomer",
        annotations = [AnnotationDescriptor(name = "path", args = ["\"/customers/{id}\""])],
        fields = [idField]
      )
    ]
  )
  val req = GeneratorRequest(generatorArg = "Ui.Routes", typeDescriptor = td, packageName = "App", sourceFile = "r.l")
  match roundTrip(req) {
    case Err(msg) -> assertTrue(false, "round trip failed: " + msg)
    case Ok(back) -> {
      val cases = back.typeDescriptor.cases
      assertEqualInt(cases.length, 2, "two cases")
      assertEqual(cases[1].name, "EditCustomer", "case name")
      assertEqual(cases[1].annotations[0].name, "path", "case annotation name")
      assertEqual(cases[1].annotations[0].args[0], "\"/customers/{id}\"", "case annotation argument source")
      assertEqual(cases[1].fields[0].fieldType.name, "CustomerId", "case field type")
    }
  }
}

test "codec: a schema 2 opaque type round-trips invariants and defaults" {
  val notes = FieldDescriptor(
    name = "notes",
    fieldType = FieldType(kind = OptionType, name = "String?", typeArgs = ["String"]),
    isPublic = false,
    annotations = [],
    defaultSource = Some(value = "None")
  )
  val td = TypeDescriptor(
    kind = Opaque,
    name = "Customer",
    packageName = "Domain",
    typeParams = [],
    fields = [notes],
    annotations = [],
    invariants = [
      InvariantDescriptor(
        source = "name.length > 0",
        message = Some(value = "Name is required"),
        line = 7,
        column = 3
      )
    ]
  )
  val req = GeneratorRequest(
    generatorArg = "Forms.Derive",
    typeDescriptor = td,
    packageName = "Domain",
    sourceFile = "c.l"
  )
  match roundTrip(req) {
    case Err(msg) -> assertTrue(false, "round trip failed: " + msg)
    case Ok(back) -> {
      val t = back.typeDescriptor
      assertTrue(match t.kind { case Opaque -> true; case _ -> false }, "opaque kind")
      assertFalse(t.fields[0].isPublic, "field visibility")
      assertEqual(unwrapOr(t.fields[0].defaultSource, ""), "None", "field default")
      assertEqual(t.invariants[0].source, "name.length > 0", "invariant source")
      assertEqual(unwrapOr(t.invariants[0].message, ""), "Name is required", "invariant message")
      assertEqualInt(t.invariants[0].line, 7, "invariant line")
    }
  }
}

test "codec: same-file declarations round-trip, and declarationNamed finds one" {
  val td = TypeDescriptor(
    kind = Record,
    name = "Customer",
    packageName = "Domain",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val tier = DeclarationDescriptor(
    name = "Tier",
    kind = DeclaredEnum,
    underlying = None,
    range = None,
    cases = [
      CaseDescriptor(name = "Standard", annotations = [], fields = []),
      CaseDescriptor(
        name = "Key",
        annotations = [AnnotationDescriptor(name = "label", args = ["\"Key account\""])],
        fields = []
      )
    ]
  )
  val limit = DeclarationDescriptor(
    name = "Limit",
    kind = DeclaredDistinct,
    underlying = Some(value = "Long"),
    range = Some(
      value = RangeDescriptor(
        min = Some(value = "0"),
        max = Some(value = "1_000"),
        maxInclusive = false
      )
    ),
    cases = []
  )
  val req = GeneratorRequest(
    generatorArg = "Forms.Derive",
    typeDescriptor = td,
    packageName = "Domain",
    sourceFile = "c.l",
    declarations = [tier, limit]
  )
  match roundTrip(req) {
    case Err(msg) -> assertTrue(false, "round trip failed: " + msg)
    case Ok(back) -> {
      assertEqualInt(back.declarations.length, 2, "two declarations")
      match declarationNamed(back, "Tier") {
        case Some(d) -> {
          assertTrue(match d.kind { case DeclaredEnum -> true; case _ -> false }, "an enum")
          assertEqual(d.cases[1].annotations[0].args[0], "\"Key account\"", "case annotation")
        }
        case None -> assertTrue(false, "Tier is found")
      }
      match declarationNamed(back, "Limit") {
        case Some(d) -> match d.range {
          case Some(r) -> {
            assertEqual(unwrapOr(r.max, ""), "1_000", "upper bound source")
            assertFalse(r.maxInclusive, "half-open")
            assertEqual(unwrapOr(d.underlying, ""), "Long", "underlying type")
          }
          case None -> assertTrue(false, "Limit has a range")
        }
        case None -> assertTrue(false, "Limit is found")
      }
      assertTrue(match declarationNamed(back, "Other") { case None -> true; case Some(_) -> false }, "absent name")
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §20. Decoding the compiler's JSON
// ─────────────────────────────────────────────────────────────────────────────
// The compiler's request for a record with one defaulted field, written as
// `Lyric.Generator` writes it (members in its order, `defaultSource` only
// when the field has a default).
func compilerRequestJson(kind: in String, declKind: in String): String {
  "{\"generatorArg\":\"G.X\",\"packageName\":\"P\",\"sourceFile\":\"p.l\"," + "\"typeDescriptor\":{\"kind\":\"" + kind +
    "\",\"name\":\"R\",\"packageName\":\"P\",\"typeParams\":[]," +
    "\"fields\":[{\"name\":\"x\",\"fieldType\":{\"kind\":\"Primitive\",\"name\":\"Int\",\"typeArgs\":[]}," +
    "\"isPublic\":true,\"annotations\":[],\"defaultSource\":\"0\"}]," +
    "\"annotations\":[],\"cases\":[],\"invariants\":[]}," +
    "\"declarations\":[{\"name\":\"A\",\"kind\":\"" +
    declKind +
    "\",\"underlying\":\"Int\",\"range\":null,\"cases\":[]}]}"
}

test "decode: the compiler's request shape decodes" {
  match decodeText(compilerRequestJson("Record", "DeclaredAlias")) {
    case Err(msg) -> assertTrue(false, "decodes: " + msg)
    case Ok(back) -> {
      assertEqualInt(back.typeDescriptor.fields.length, 1, "one field")
      assertTrue(
        match back.typeDescriptor.fields[0].defaultSource { case Some(d) -> d == "0"; case None -> false },
        "the default's source"
      )
      assertEqualInt(back.declarations.length, 1, "one declaration")
      assertTrue(match back.declarations[0].kind { case DeclaredAlias -> true; case _ -> false }, "an alias")
    }
  }
}

test "decode: a field without a default decodes with no defaultSource" {
  val json = "{\"generatorArg\":\"G.X\",\"packageName\":\"P\",\"sourceFile\":\"p.l\"," +
    "\"typeDescriptor\":{\"kind\":\"Record\",\"name\":\"R\",\"packageName\":\"P\",\"typeParams\":[]," +
    "\"fields\":[{\"name\":\"x\",\"fieldType\":{\"kind\":\"Primitive\",\"name\":\"Int\",\"typeArgs\":[]}," +
    "\"isPublic\":true,\"annotations\":[]}],\"annotations\":[],\"cases\":[],\"invariants\":[]},\"declarations\":[]}"
  match decodeText(json) {
    case Err(msg) -> assertTrue(false, "decodes: " + msg)
    case Ok(back) -> assertTrue(
      match back.typeDescriptor.fields[0].defaultSource { case Some(_) -> false; case None -> true },
      "no default"
    )
  }
}

test "decode: an unknown kind is an error, not a silent record" {
  assertTrue(
    match decodeText(compilerRequestJson("Widget", "DeclaredAlias")) {
      case Err(msg) -> msg.contains("Widget")
      case Ok(_) -> false
    },
    "unknown item kind rejected"
  )
  assertTrue(
    match decodeText(compilerRequestJson("Record", "Gizmo")) {
      case Err(msg) -> msg.contains("Gizmo")
      case Ok(_) -> false
    },
    "unknown declaration kind rejected"
  )
}

test "decode: a missing member is an error naming it" {
  assertTrue(
    match decodeText("{\"generatorArg\":\"G.X\"}") { case Err(msg) -> msg.contains("packageName"); case Ok(_) -> false },
    "missing member rejected"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §21. projectPathWithin — the ProjectRead guard
// ─────────────────────────────────────────────────────────────────────────────
func rootsOf(xs: in slice[String]): List[String] {
  val l: List[String] = newList()
  var i = 0
  while i < xs.length {
    l.add(xs[i])
    i += 1
  }
  l
}

test "projectPathWithin: a path under a granted root" {
  assertTrue(projectPathWithin("schemas/order.json", rootsOf(["schemas"])), "under the root")
  assertTrue(projectPathWithin("schemas", rootsOf(["schemas"])), "the root itself")
  assertTrue(projectPathWithin("a/b/c.txt", rootsOf(["."])), "the whole project")
  assertFalse(projectPathWithin("schemasx/order.json", rootsOf(["schemas"])), "a sibling with a shared prefix")
  assertFalse(projectPathWithin("src/a.l", rootsOf(["schemas"])), "another directory")
  assertFalse(projectPathWithin("src/a.l", rootsOf([])), "no roots")
}

test "projectPathWithin: escapes and absolute paths are refused" {
  val all = rootsOf(["."])
  assertFalse(projectPathWithin("../secret", all), "parent segment")
  assertFalse(projectPathWithin("a/../../secret", all), "inner parent segment")
  assertFalse(projectPathWithin("/etc/passwd", all), "absolute")
  assertFalse(projectPathWithin("C:/x", all), "drive")
  assertFalse(projectPathWithin("a\\b", all), "backslash")
  assertFalse(projectPathWithin("a//b", all), "empty segment")
  assertFalse(projectPathWithin("./a", all), "dot segment")
  assertFalse(projectPathWithin("", all), "empty")
}
