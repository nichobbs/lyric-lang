//! annotation_meta_emit_self_test.l — exercises Lyric.AnnotationMetaEmit
//! (#6866, D-progress-941): collecting `config { }` field annotations from
//! a parsed `SourceFile` and serializing them to the `Lyric.AnnotationMeta`
//! JSON payload.
//!
//! Run via `lyric test lyric-compiler/lyric/annotation_meta_emit_self_test.l`.
@test_module
package Lyric.AnnotationMetaEmit.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Json
import Lyric.Lexer
import Lyric.Parser
import Lyric.AnnotationMetaEmit

func parseOk(src: in String): SourceFile {
  val pr = parse(src)
  if pr.diagnostics.count > 0 {
    panic("parseOk: parser produced diagnostics, refusing to test against ill-formed source")
  }
  pr.file
}

test "no config blocks collects nothing" {
  val src = "package P\n" + "pub func a(): Int { 1 }\n"
  val sf = parseOk(src)
  val fields = collectAnnotatedFields(sf)
  assertEqualInt(fields.count, 0, "no config blocks -> no annotated fields")
  assertEqual(emitAnnotationMetaJson(fields), "[]", "empty collection serializes to the bare empty array")
}

test "config block with no annotated fields collects nothing" {
  val src = "package P\n" + "config Db {\n" + "  host: String = \"localhost\"\n" + "}\n"
  val sf = parseOk(src)
  val fields = collectAnnotatedFields(sf)
  assertEqualInt(fields.count, 0, "unannotated field is not collected")
}

test "named-arg annotation collected with its argument" {
  val src = "package P\n" + "config Db {\n" + "  @secretsManager(key = \"prod/db/password\")\n" + "  password: String\n" +
    "}\n"
  val sf = parseOk(src)
  val fields = collectAnnotatedFields(sf)
  assertEqualInt(fields.count, 1, "one annotated field")
  val f = fields[0]
  assertEqual(f.configName, "Db", "config name recorded")
  assertEqual(f.fieldName, "password", "field name recorded")
  assertEqual(f.annotationName, "secretsManager", "annotation name recorded")
  assertEqualInt(f.args.count, 1, "one arg")
  assertEqual(f.args[0].argName, "key", "named arg name recorded")
  assertEqual(f.args[0].argKind, "string", "string-valued arg kind recorded")
  assertEqual(f.args[0].argValue, "prod/db/password", "named arg value recorded")
}

test "positional-literal annotation collected" {
  val src = "package P\n" + "config Db {\n" + "  @parameterStore(\"/app/db/host\")\n" + "  host: String\n" + "}\n"
  val sf = parseOk(src)
  val fields = collectAnnotatedFields(sf)
  assertEqualInt(fields.count, 1, "one annotated field")
  assertEqual(fields[0].annotationName, "parameterStore", "annotation name recorded")
  assertEqualInt(fields[0].args.count, 1, "one positional arg")
  assertEqual(fields[0].args[0].argName, "", "positional arg has no name")
  assertEqual(fields[0].args[0].argKind, "string", "positional string arg kind recorded")
  assertEqual(fields[0].args[0].argValue, "/app/db/host", "positional arg value recorded")
}

// #7186 review: the actual documented real-world shape (docs/35 §7.1) mixes
// a positional arg with a named one in the same annotation, e.g.
// `@secretsManager("my-service/prod", key = "dbPassword")` (extract a JSON
// field from a structured secret).  `collectArgs` walks the arg list
// generically per-index regardless of the AAName/ABare/ALiteral mix, but
// that was previously untested.
test "mixed positional and named args in one annotation collected in order" {
  val src = "package P\n" + "config Db {\n" + "  @secretsManager(\"my-service/prod\", key = \"dbPassword\")\n" +
    "  password: String\n" +
    "}\n"
  val sf = parseOk(src)
  val fields = collectAnnotatedFields(sf)
  assertEqualInt(fields.count, 1, "one annotated field")
  assertEqual(fields[0].annotationName, "secretsManager", "annotation name recorded")
  assertEqualInt(fields[0].args.count, 2, "two args")
  assertEqual(fields[0].args[0].argName, "", "first (positional) arg has no name")
  assertEqual(fields[0].args[0].argKind, "string", "first arg kind recorded")
  assertEqual(fields[0].args[0].argValue, "my-service/prod", "first arg value recorded")
  assertEqual(fields[0].args[1].argName, "key", "second (named) arg name recorded")
  assertEqual(fields[0].args[1].argKind, "string", "second arg kind recorded")
  assertEqual(fields[0].args[1].argValue, "dbPassword", "second arg value recorded")
}

test "multiple annotated fields across multiple config blocks, in source order" {
  val src = "package P\n" + "config A {\n" + "  @secretsManager(key = \"a\")\n" + "  x: String\n" + "  y: String\n" +
    "}\n" +
    "config B {\n" +
    "  @parameterStore(\"b\")\n" +
    "  z: String\n" +
    "}\n"
  val sf = parseOk(src)
  val fields = collectAnnotatedFields(sf)
  assertEqualInt(fields.count, 2, "two annotated fields total (unannotated y skipped)")
  assertEqual(fields[0].configName, "A", "first annotated field from config A")
  assertEqual(fields[0].fieldName, "x", "first annotated field is x")
  assertEqual(fields[1].configName, "B", "second annotated field from config B")
  assertEqual(fields[1].fieldName, "z", "second annotated field is z")
}

test "field with multiple annotations each collected separately" {
  val src = "package P\n" + "config A {\n" + "  @secretsManager(key = \"k\")\n" + "  @stable(since = \"0.1\")\n" +
    "  x: String\n" +
    "}\n"
  val sf = parseOk(src)
  val fields = collectAnnotatedFields(sf)
  assertEqualInt(fields.count, 2, "both annotations on the same field are collected separately")
  assertEqual(fields[0].annotationName, "secretsManager", "first annotation")
  assertEqual(fields[1].annotationName, "stable", "second annotation")
  assertEqual(fields[1].args[0].argName, "since", "second annotation's arg name")
}

test "emitAnnotationMetaJson round-trips through Std.Json.tryParseJson" {
  val src = "package P\n" + "config Db {\n" + "  @secretsManager(key = \"prod/db/password\")\n" + "  password: String\n" +
    "}\n"
  val sf = parseOk(src)
  val fields = collectAnnotatedFields(sf)
  val json = emitAnnotationMetaJson(fields)
  match tryParseJson(json) {
    case Ok(doc) -> {
      disposeJson(doc)
    }
    case Err(e) -> assertTrue(false, "emitted JSON failed to parse: " + e)
  }
}
