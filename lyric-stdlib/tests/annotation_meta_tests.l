//! tests/annotation_meta_tests.l - test suite for Std.AnnotationMeta.
//!
//! The first group exercises the pure decoder (`parseAnnotationMeta`) on
//! hand-written documents, including every malformed shape.  The second
//! group reads the metadata the compiler embedded in THIS test's own
//! assembly / jar, so it covers the full path end to end on whichever
//! target runs it: the `config { }` blocks declared below are the fixture.
@test_module
package Std.AnnotationMeta.Tests

import Std.Core
import Std.Collections
import Std.Testing
import Std.AnnotationMeta

config Database {
  host: String = "localhost"
  @sensitive
  @secretsManager("my-service/prod", key = "dbPassword")
  password: String
}

config Auth {
  @sensitive
  @secretsManager("my-service/prod", key = "jwtSecret")
  jwtSecret: String
  @sensitive
  @parameterStore("/my-service/signing-key")
  signingKey: String
}

func fieldNames(fs: in List[AnnotatedField]): String {
  var s = ""
  var i = 0
  while i < fs.count {
    if i > 0 {
      s = s + ","
    }
    s = s + fs[i].configName + "." + fs[i].fieldName
    i = i + 1
  }
  s
}

func mustFields(r: in Result[List[AnnotatedField], AnnotationMetaError]): List[AnnotatedField] {
  match r {
    case Ok(fs) -> fs
    case Err(e) -> {
      assertTrue(false, "expected Ok, got " + errorMessage(e))
      newList()
    }
  }
}

func assertSomeString(o: in Option[String], expected: in String, label: in String): Unit {
  match o {
    case Some(v) -> assertEqual(v, expected, label)
    case None -> assertTrue(false, label + " (expected Some, got None)")
  }
}

func assertNoneString(o: in Option[String], label: in String): Unit {
  match o {
    case None -> ()
    case Some(v) -> assertTrue(false, label + " (expected None, got Some(" + v + "))")
  }
}

func assertMalformed(json: in String, fragment: in String, label: in String): Unit {
  match parseAnnotationMeta(json) {
    case Ok(_) -> assertTrue(false, label + " (expected Malformed, got Ok)")
    case Err(Malformed(message)) -> assertTrue(message.contains(fragment), label + " (message was: " + message + ")")
    case Err(Unsupported(reason)) -> assertTrue(false, label + " (expected Malformed, got Unsupported)")
  }
}

// ── Pure decoder ────────────────────────────────────────────────────────────
test "parseAnnotationMeta decodes an empty document" {
  assertEqualInt(mustFields(parseAnnotationMeta("[]")).count, 0, "empty array yields no fields")
}

test "parseAnnotationMeta decodes fields, annotations and every argument kind" {
  val json = "[{\"config\":\"Db\",\"field\":\"password\",\"annotation\":\"secretsManager\",\"args\":[" +
    "{\"name\":\"\",\"kind\":\"string\",\"value\":\"prod/db\"}," +
    "{\"name\":\"key\",\"kind\":\"string\",\"value\":\"pw\"}," +
    "{\"name\":\"ttl\",\"kind\":\"int\",\"value\":\"30\"}," +
    "{\"name\":\"\",\"kind\":\"bare\",\"value\":\"sticky\"}]}," +
    "{\"config\":\"Db\",\"field\":\"host\",\"annotation\":\"sensitive\",\"args\":[]}]"
  val fs = mustFields(parseAnnotationMeta(json))
  assertEqualInt(fs.count, 2, "two entries")
  assertEqual(fs[0].configName, "Db", "config name")
  assertEqual(fs[0].fieldName, "password", "field name")
  assertEqual(fs[0].annotationName, "secretsManager", "annotation name")
  assertEqualInt(fs[0].args.count, 4, "four args")
  assertEqual(fs[0].args[2].kind, "int", "int arg kind")
  assertEqual(fs[0].args[3].kind, "bare", "bare arg kind")
  assertSomeString(positionalArg(fs[0], 0), "prod/db", "first positional")
  assertSomeString(positionalArg(fs[0], 1), "sticky", "second positional skips named args")
  assertNoneString(positionalArg(fs[0], 2), "no third positional")
  assertSomeString(namedArg(fs[0], "key"), "pw", "named arg")
  assertNoneString(namedArg(fs[0], "missing"), "absent named arg")
  assertNoneString(namedArg(fs[0], ""), "empty name never matches a positional")
  assertEqualInt(fs[1].args.count, 0, "no-arg annotation")
}

test "parseAnnotationMeta preserves non-ASCII and escaped text" {
  val json = "[{\"config\":\"C\",\"field\":\"f\",\"annotation\":\"a\",\"args\":[" +
    "{\"name\":\"\",\"kind\":\"string\",\"value\":\"caf\\u00e9 \\\"q\\\"\"}]}]"
  val fs = mustFields(parseAnnotationMeta(json))
  assertSomeString(positionalArg(fs[0], 0), "café \"q\"", "unescaped value")
}

test "parseAnnotationMeta rejects malformed documents" {
  assertMalformed("", "empty", "empty input")
  assertMalformed("{", "unexpected", "truncated JSON")
  assertMalformed("{}", "not a JSON array", "object root")
  assertMalformed("[1]", "missing string member 'config'", "non-object entry")
  assertMalformed("[{\"config\":\"C\",\"field\":\"f\",\"args\":[]}]", "'annotation'", "missing annotation")
  assertMalformed("[{\"config\":\"C\",\"field\":\"f\",\"annotation\":\"a\"}]", "'args'", "missing args")
  assertMalformed(
    "[{\"config\":\"C\",\"field\":\"f\",\"annotation\":\"a\",\"args\":[{\"name\":\"\",\"kind\":\"string\"}]}]",
    "args[0]",
    "arg missing value"
  )
}

// ── Embedded metadata of this test's own assembly / jar ─────────────────────
test "fieldsWithAnnotation finds every field carrying an annotation" {
  val fs = mustFields(fieldsWithAnnotation("secretsManager"))
  assertEqual(fieldNames(fs), "Database.password,Auth.jwtSecret", "secretsManager fields in source order")
  assertSomeString(positionalArg(fs[0], 0), "my-service/prod", "secret name")
  assertSomeString(namedArg(fs[0], "key"), "dbPassword", "secret key")
  assertSomeString(namedArg(fs[1], "key"), "jwtSecret", "second secret key")
}

test "fieldsWithAnnotation accepts the leading at-sign" {
  val fs = mustFields(fieldsWithAnnotation("@parameterStore"))
  assertEqual(fieldNames(fs), "Auth.signingKey", "parameterStore field")
  assertSomeString(positionalArg(fs[0], 0), "/my-service/signing-key", "parameter path")
}

test "fieldsWithAnnotation reports a field once per matching annotation" {
  val fs = mustFields(fieldsWithAnnotation("sensitive"))
  assertEqual(fieldNames(fs), "Database.password,Auth.jwtSecret,Auth.signingKey", "sensitive fields")
  assertEqualInt(fs[0].args.count, 0, "bare annotation has no args")
}

test "fieldsWithAnnotation returns an empty list for an unused annotation" {
  assertEqualInt(mustFields(fieldsWithAnnotation("neverWritten")).count, 0, "no matches")
}

test "allAnnotatedFields lists every annotation of the embedded configs" {
  val fs = mustFields(allAnnotatedFields())
  assertEqualInt(fs.count, 6, "six annotations across the two fixture configs")
}
