//! stdlib_builders_self_test.l — output of the stdlib functions rewritten
//! onto `Std.String.StringBuilder` (#7270, #7271, #7272, #7273, #7274, #7278).
//!
//! Each of these used to build its result with `acc = acc + piece`, which is
//! quadratic in the output length. The rewrites append escape-free runs as
//! single substrings, so the cases below concentrate on the run boundaries:
//! text before, between and after entities and escapes, empty input, and
//! input that is nothing but escapes.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/stdlib_builders_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/stdlib_builders_self_test.l
//! Imports only `Std.*`.
@test_module
package Lyric.StdlibBuildersSelfTest

import Std.Core
import Std.Collections
import Std.String
import Std.Format
import Std.Encoding
import Std.Xml
import Std.Yaml
import Std.ProcessCapture
import Std.Testing

func textOf(src: in String): String {
  match parseXml(src) {
    case Ok(doc) -> textContent(doc.root)
    case Err(_) -> "<parse error>"
  }
}

func attrOf(src: in String, name: in String): String {
  match parseXml(src) {
    case Ok(doc) -> match getAttribute(doc.root, name) { case Some(v) -> v; case None -> "<missing>" }
    case Err(_) -> "<parse error>"
  }
}

func jsonString(src: in String): String {
  match parseJson(src) {
    case Ok(YString(s)) -> s
    case Ok(_) -> "<not a string>"
    case Err(_) -> "<parse error>"
  }
}

func yamlKey(src: in String, key: in String): String {
  match parseYaml(src) {
    case Ok(v) -> match getString(v, key) { case Some(s) -> s; case None -> "<missing>" }
    case Err(_) -> "<parse error>"
  }
}

test "repeat, padLeft and padRight" {
  assertEqual(repeat("ab", 3), "ababab", "repeat")
  assertEqual(repeat("ab", 0), "", "repeat zero")
  assertEqual(padLeft("42", 5, '0'), "00042", "padLeft")
  assertEqual(padRight("hi", 5, '.'), "hi...", "padRight")
  assertEqual(padLeft("toolong", 3, ' '), "toolong", "padLeft no-op")
}

test "encodeHex and encodeBase64" {
  assertEqual(encodeHex([0u8, 171u8, 255u8]), "00ABFF", "hex")
  assertEqual(encodeBase64(encodeUtf8("Man")), "TWFu", "base64 full group")
  assertEqual(encodeBase64(encodeUtf8("Ma")), "TWE=", "base64 one pad")
  assertEqual(encodeBase64(encodeUtf8("M")), "TQ==", "base64 two pad")
  assertEqual(encodeBase64(encodeUtf8("")), "", "base64 empty")
}

test "tryDecodeUtf8 round-trips mixed-width text and rejects bad input" {
  val text = "aé€z"
  match tryDecodeUtf8(encodeUtf8(text)) {
    case Some(s) -> assertEqual(s, text, "round trip")
    case None -> assertTrue(false, "expected valid UTF-8")
  }
  match tryDecodeUtf8([192u8, 128u8]) {
    case Some(_) -> assertTrue(false, "overlong must be rejected")
    case None -> assertTrue(true, "overlong rejected")
  }
}

test "XML text and attributes keep text around entities" {
  assertEqual(textOf("<a>x &amp; y</a>"), "x & y", "entity in the middle")
  assertEqual(textOf("<a>&lt;tag&gt;</a>"), "<tag>", "entities at both ends")
  assertEqual(textOf("<a>&amp;&amp;</a>"), "&&", "only entities")
  assertEqual(textOf("<a>plain</a>"), "plain", "no entities")
  assertEqual(textOf("<a>one<b>two</b>three</a>"), "onetwothree", "nested textContent")
  assertEqual(attrOf("<a k=\"p&quot;q\"/>", "k"), "p\"q", "attribute entity")
}

test "JSON and YAML quoted strings keep text around escapes" {
  assertEqual(jsonString("\"ab\\ncd\""), "ab\ncd", "escape in the middle")
  assertEqual(jsonString("\"\\t\\u0041\\\\\""), "\tA\\", "only escapes")
  assertEqual(jsonString("\"\""), "", "empty")
  assertEqual(yamlKey("k: 'it''s'", "k"), "it's", "single-quoted doubled quote")
}

test "duplicate keys are still rejected" {
  match parseJson("{\"a\": 1, \"a\": 2}") {
    case Ok(_) -> assertTrue(false, "duplicate JSON key accepted")
    case Err(_) -> assertTrue(true, "duplicate JSON key rejected")
  }
  match parseYaml("a: 1\na: 2\n") {
    case Ok(_) -> assertTrue(false, "duplicate YAML key accepted")
    case Err(_) -> assertTrue(true, "duplicate YAML key rejected")
  }
}

test "quoteArg and buildArgString" {
  assertEqual(quoteArg("plain"), "\"plain\"", "plain")
  assertEqual(quoteArg("a\"b"), "\"a\\\"b\"", "embedded quote")
  assertEqual(quoteArg("dir\\"), "\"dir\\\\\"", "trailing backslash doubled")
  assertEqual(quoteArg("a\\b"), "\"a\\b\"", "inner backslash kept")
  val args: List[String] = newList()
  args.add("x")
  args.add("y z")
  assertEqual(buildArgString(args), "\"x\" \"y z\"", "joined")
}
