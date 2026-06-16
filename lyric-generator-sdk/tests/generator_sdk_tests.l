//! generator_sdk_tests.l — @test_module for Lyric.GeneratorSdk
//!
//! Test suite for the public API of the generator SDK: request serialization,
//! response parsing, and the types that comprise the contract between the
//! compiler and generator implementations.

@test_module
package Lyric.GeneratorSdk.Tests

import Std.Core
import Std.Testing
import Lyric.GeneratorSdk

// ─────────────────────────────────────────────────────────────────────────────
// §1. AnnotationDescriptor — annotation values
// ─────────────────────────────────────────────────────────────────────────────

test "AnnotationDescriptor: name and empty args" {
  val ann = AnnotationDescriptor(
    name = "required",
    args = []
  )
  assertTrue(ann.name == "required", "name field")
  assertTrue(ann.args.toArray().count == 0, "empty args array")
}

test "AnnotationDescriptor: name with multiple args" {
  val ann = AnnotationDescriptor(
    name = "since",
    args = ["\"1.0\"", "\"Json\""]
  )
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
  val matched = match kind {
    case Primitive -> true
    case _ -> false
  }
  assertTrue(matched, "Primitive variant")
}

test "FieldTypeKind.Slice: can be matched" {
  val kind = Slice
  val matched = match kind {
    case Slice -> true
    case _ -> false
  }
  assertTrue(matched, "Slice variant")
}

test "FieldTypeKind.OptionType: can be matched" {
  val kind = OptionType
  val matched = match kind {
    case OptionType -> true
    case _ -> false
  }
  assertTrue(matched, "OptionType variant")
}

test "FieldTypeKind.ResultType: can be matched" {
  val kind = ResultType
  val matched = match kind {
    case ResultType -> true
    case _ -> false
  }
  assertTrue(matched, "ResultType variant")
}

test "FieldTypeKind.Named: can be matched" {
  val kind = Named
  val matched = match kind {
    case Named -> true
    case _ -> false
  }
  assertTrue(matched, "Named variant")
}

test "FieldTypeKind.Generic: can be matched" {
  val kind = Generic
  val matched = match kind {
    case Generic -> true
    case _ -> false
  }
  assertTrue(matched, "Generic variant")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. FieldType — resolved type information
// ─────────────────────────────────────────────────────────────────────────────

test "FieldType: primitive Int" {
  val ft = FieldType(
    kind = Primitive,
    name = "Int",
    typeArgs = []
  )
  assertTrue(ft.name == "Int", "name field")
  assertTrue(ft.typeArgs.toArray().count == 0, "no type args")
}

test "FieldType: slice with String element" {
  val ft = FieldType(
    kind = Slice,
    name = "slice[String]",
    typeArgs = ["String"]
  )
  assertTrue(ft.name == "slice[String]", "name includes brackets")
  assertTrue(ft.typeArgs.toArray().count == 1, "one type arg")
  assertTrue(ft.typeArgs.toArray()[0] == "String", "element type")
}

test "FieldType: Option with String" {
  val ft = FieldType(
    kind = OptionType,
    name = "Option[String]",
    typeArgs = ["String"]
  )
  assertTrue(ft.kind == OptionType, "kind")
  assertTrue(ft.typeArgs.toArray()[0] == "String", "inner type")
}

test "FieldType: Result with two type args" {
  val ft = FieldType(
    kind = ResultType,
    name = "Result[Int, String]",
    typeArgs = ["Int", "String"]
  )
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
  val matched = match kind {
    case Record -> true
    case _ -> false
  }
  assertTrue(matched, "Record variant")
}

test "ItemKind.ExposedRecord: can be matched" {
  val kind = ExposedRecord
  val matched = match kind {
    case ExposedRecord -> true
    case _ -> false
  }
  assertTrue(matched, "ExposedRecord variant")
}

test "ItemKind.Union: can be matched" {
  val kind = Union
  val matched = match kind {
    case Union -> true
    case _ -> false
  }
  assertTrue(matched, "Union variant")
}

test "ItemKind.Interface: can be matched" {
  val kind = Interface
  val matched = match kind {
    case Interface -> true
    case _ -> false
  }
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
// §8. serializeRequest — round-trip via JSON
// ─────────────────────────────────────────────────────────────────────────────

test "serializeRequest: minimal request" {
  val td = TypeDescriptor(
    kind = Record,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Pkg",
    sourceFile = "f.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("\"schemaVersion\":\"1\""), "schema version")
  assertTrue(json.contains("\"generatorArg\":\"Gen\""), "generator arg")
  assertTrue(json.contains("\"name\":\"Type\""), "type name")
  assertTrue(json.contains("\"packageName\":\"Pkg\""), "package name")
  assertTrue(json.contains("\"sourceFile\":\"f.l\""), "source file")
}

test "serializeRequest: request with special characters" {
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
  val json = serializeRequest(req)
  assertTrue(json.contains("\\\""), "quote escaped")
  assertTrue(json.contains("\\\\"), "backslash escaped")
}

test "serializeRequest: request with type parameters" {
  val td = TypeDescriptor(
    kind = Record,
    name = "Container",
    packageName = "Std",
    typeParams = ["T", "E"],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Std",
    sourceFile = "c.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("[\"T\",\"E\"]"), "type params serialized")
}

test "serializeRequest: request with fields" {
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
  val req = GeneratorRequest(
    generatorArg = "Proto",
    typeDescriptor = td,
    packageName = "Models",
    sourceFile = "user.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("\"name\":\"id\""), "field name")
  assertTrue(json.contains("\"Primitive\""), "field type kind")
}

test "serializeRequest: ExposedRecord variant" {
  val td = TypeDescriptor(
    kind = ExposedRecord,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Pkg",
    sourceFile = "f.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("ExposedRecord"), "ItemKind ExposedRecord serialized")
}

test "serializeRequest: Union variant" {
  val td = TypeDescriptor(
    kind = Union,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Pkg",
    sourceFile = "f.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("Union"), "ItemKind Union serialized")
}

test "serializeRequest: Interface variant" {
  val td = TypeDescriptor(
    kind = Interface,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Pkg",
    sourceFile = "f.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("Interface"), "ItemKind Interface serialized")
}

test "serializeRequest: Slice field type" {
  val ft = FieldType(kind = Slice, name = "T", typeArgs = [])
  val fd = FieldDescriptor(
    name = "f",
    fieldType = ft,
    isPublic = true,
    annotations = []
  )
  val td = TypeDescriptor(
    kind = Record,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [fd],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Pkg",
    sourceFile = "f.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("Slice"), "FieldTypeKind Slice in JSON")
}

test "serializeRequest: Generic field type" {
  val ft = FieldType(kind = Generic, name = "T", typeArgs = [])
  val fd = FieldDescriptor(
    name = "f",
    fieldType = ft,
    isPublic = true,
    annotations = []
  )
  val td = TypeDescriptor(
    kind = Record,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [fd],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Pkg",
    sourceFile = "f.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("Generic"), "FieldTypeKind Generic in JSON")
}

test "serializeRequest: field with annotations" {
  val ann = AnnotationDescriptor(name = "required", args = [])
  val ft = FieldType(kind = Primitive, name = "String", typeArgs = [])
  val fd = FieldDescriptor(
    name = "email",
    fieldType = ft,
    isPublic = true,
    annotations = [ann]
  )
  val td = TypeDescriptor(
    kind = Record,
    name = "User",
    packageName = "Pkg",
    typeParams = [],
    fields = [fd],
    annotations = []
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Pkg",
    sourceFile = "f.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("\"name\":\"required\""), "annotation name in JSON")
}

test "serializeRequest: annotation with arguments" {
  val ann = AnnotationDescriptor(name = "since", args = ["\"1.0\""])
  val td = TypeDescriptor(
    kind = Record,
    name = "Type",
    packageName = "Pkg",
    typeParams = [],
    fields = [],
    annotations = [ann]
  )
  val req = GeneratorRequest(
    generatorArg = "Gen",
    typeDescriptor = td,
    packageName = "Pkg",
    sourceFile = "f.l"
  )
  val json = serializeRequest(req)
  assertTrue(json.contains("\"args\":[\"\\\"1.0\\\"\"]"), "annotation args serialized")
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. GeneratorDiagnosticSeverity — diagnostic levels
// ─────────────────────────────────────────────────────────────────────────────

test "GeneratorDiagnosticSeverity.Error: can be matched" {
  val sev = Error
  val matched = match sev {
    case Error -> true
    case _ -> false
  }
  assertTrue(matched, "Error variant")
}

test "GeneratorDiagnosticSeverity.Warning: can be matched" {
  val sev = Warning
  val matched = match sev {
    case Warning -> true
    case _ -> false
  }
  assertTrue(matched, "Warning variant")
}

test "GeneratorDiagnosticSeverity.Info: can be matched" {
  val sev = Info
  val matched = match sev {
    case Info -> true
    case _ -> false
  }
  assertTrue(matched, "Info variant")
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. GeneratorDiagnostic — diagnostic messages
// ─────────────────────────────────────────────────────────────────────────────

test "GeneratorDiagnostic: error with code" {
  val diag = GeneratorDiagnostic(
    severity = Error,
    message = "Invalid type",
    code = Some(value = "G001")
  )
  assertTrue(diag.severity == Error, "severity")
  assertTrue(diag.message == "Invalid type", "message")
  val hasCode = match diag.code {
    case Some(_) -> true
    case None -> false
  }
  assertTrue(hasCode, "has code")
}

test "GeneratorDiagnostic: warning without code" {
  val diag = GeneratorDiagnostic(
    severity = Warning,
    message = "Unused type param",
    code = None
  )
  assertTrue(diag.severity == Warning, "severity")
  val hasCode = match diag.code {
    case Some(_) -> true
    case None -> false
  }
  assertFalse(hasCode, "no code")
}

test "GeneratorDiagnostic: info with empty code string" {
  val diag = GeneratorDiagnostic(
    severity = Info,
    message = "Processing started",
    code = Some(value = "")
  )
  assertTrue(diag.severity == Info, "severity")
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. GeneratorResponse — response contract
// ─────────────────────────────────────────────────────────────────────────────

test "GeneratorResponse: basic response" {
  val resp = GeneratorResponse(
    lyricSource = "pub func generated(): Unit {}",
    additionalImports = [],
    diagnostics = []
  )
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
  val resp = GeneratorResponse(
    lyricSource = "",
    additionalImports = [],
    diagnostics = [diag1, diag2]
  )
  val diags = resp.diagnostics.toArray()
  assertTrue(diags.count == 2, "two diagnostics")
  assertTrue(diags[0].severity == Error, "first is error")
  val hasCode = match diags[1].code {
    case Some(_) -> true
    case None -> false
  }
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
  val json = serializeRequest(req)
  assertTrue(json.contains("ComplexType"), "type name present")
  assertTrue(json.contains("Slice"), "field kind present")
  assertTrue(json.contains("ResultType"), "result type present")
  assertTrue(json.contains("\"required\""), "annotation present")
}

