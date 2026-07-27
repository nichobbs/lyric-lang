//! native_image_self_test.l — validates the four GraalVM native-image config
//! JSON documents `Jvm.NativeImage` generates (Stage B7; release path D131).
//!
//! These are strings hand-assembled by concatenation, fed straight to
//! `native-image -H:ConfigurationFileDirectories=`, and native-image reports a
//! malformed one *inside* its build-summary block, still prints "Finished
//! generating", and exits 0 without writing a binary — so a schema or escaping
//! regression here is close to invisible at the CLI.  Two such bugs shipped
//! undetected precisely because nothing asserted this output (D131):
//!
//!   - `jni-config.json` / `proxy-config.json` used object forms
//!     (`{"jni": []}`) where both schemas require a top-level array.
//!   - the resource `pattern` is a java.util.regex inside a JSON string, so a
//!     literal `.` needs a regex escape that must itself survive JSON
//!     encoding — under-escaping it by one level yields a bare `\.`, which is
//!     not a legal JSON escape at all (RFC 8259).
//!
//! Every case therefore parses the generated text as real JSON rather than
//! string-matching it: parsing is the property that actually broke.
//!
//! Runs in CI via:
//!
//!   lyric test lyric-compiler/lyric/native_image_self_test.l
@test_module
package Lyric.NativeImageSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Json as Json
import Std.Testing
import Jvm.NativeImage as NI

// Parse `text`, failing the assertion with the parser's own message when it is
// not valid JSON.  Returns the decoded `resources.includes[0].pattern`, which
// is the only field any of these documents carries.
func patternOf(text: in String, label: in String): String {
  val doc = match Json.tryParseJson(text) {
    case Ok(d) -> d
    case Err(e) -> {
      assertTrue(false, label + ": generated text is not valid JSON: " + e)
      return ""
    }
  }
  val includes = Json.getProperty(Json.getProperty(Json.rootElement(doc), "resources"), "includes")
  var cur = Json.enumerateArray(includes)
  if not Json.arrayMoveNext(cur) {
    assertTrue(false, label + ": resources.includes is empty")
    Json.disposeJson(doc)
    return ""
  }
  val pattern = Json.getString(Json.getProperty(Json.arrayCurrent(cur), "pattern"))
  Json.disposeJson(doc)
  pattern
}

// Assert `text` parses as JSON and is the empty top-level array these three
// schemas require.  `[]` is not interchangeable with `{"...": []}` here:
// native-image rejects the object form with "first level of document must be
// an array of class descriptors".
func assertEmptyJsonArray(text: in String, label: in String): Unit {
  assertEqual(Str.trim(text), "[]", label + ": must be a top-level empty array, not an object wrapper")
  val doc = match Json.tryParseJson(text) {
    case Ok(d) -> d
    case Err(e) -> {
      assertTrue(false, label + ": generated text is not valid JSON: " + e)
      return ()
    }
  }
  var cur = Json.enumerateArray(Json.rootElement(doc))
  assertTrue(not Json.arrayMoveNext(cur), label + ": array must be empty")
  Json.disposeJson(doc)
}

test "reflectConfigJson: valid, empty, top-level array" {
  assertEmptyJsonArray(NI.reflectConfigJson(), "reflect-config.json")
}

test "proxyConfigJson: valid, empty, top-level array (not an object wrapper)" {
  assertEmptyJsonArray(NI.proxyConfigJson(), "proxy-config.json")
}

test "jniConfigJson: valid, empty, top-level array (not an object wrapper)" {
  assertEmptyJsonArray(NI.jniConfigJson(), "jni-config.json")
}

test "resourceConfigJson: is valid JSON for a dotted package name" {
  // The under-escaped form emitted a bare `\.`, which no JSON parser accepts.
  val _ = patternOf(NI.resourceConfigJson("My.App.Server"), "resource-config.json")
}

test "resourceConfigJson: package-name dots decode to escaped regex dots, not wildcards" {
  val pattern = patternOf(NI.resourceConfigJson("My.App"), "resource-config.json")
  assertEqual(
    pattern,
    "META-INF/lyric/My\\.App\\.lyric-contract",
    "each `.` is regex-escaped so it matches a literal dot rather than any character"
  )
}

test "resourceConfigJson: a dot-free package name needs no escaping" {
  val pattern = patternOf(NI.resourceConfigJson("Demo"), "resource-config.json")
  assertEqual(pattern, "META-INF/lyric/Demo\\.lyric-contract", "only the suffix separator is escaped")
}

test "resourceConfigJsonAll: is valid JSON and matches any package's contract blob" {
  val pattern = patternOf(NI.resourceConfigJsonAll(), "resource-config.json (all)")
  assertEqual(
    pattern,
    "META-INF/lyric/[^/]+\\.lyric-contract",
    "one pattern covering every package in the bundled release JAR"
  )
}
