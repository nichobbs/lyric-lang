//! union_case_collision_self_test.l — regression test for #2899.
//!
//! Both `Std.Xml.XmlError` and `Std.Yaml.YamlError` declare a case
//! named `InvalidDocument(message: String)`.  Before the fix the
//! self-hosted MSIL emitter's `unionCaseCtorByName` map was a
//! `Map[String, String]` keyed by the *simple* case name, so whichever
//! package registered its `InvalidDocument` case second overwrote the
//! first, and every `InvalidDocument(...)` construction anywhere in the
//! bundle — including inside `Std.Xml.parseXml` — would silently bind
//! to the wrong union's ctor and throw `MissingMethodException` at
//! runtime.
//!
//! The fix (#2899) changes `unionCaseCtorByName` to a multimap and
//! adds `pickCaseFqnByScope` / `pickCaseFqnByScrutinee` disambiguation
//! helpers that prefer same-package or imported-package candidates over
//! unrelated ones.
//!
//! Both `Std.Xml` and `Std.Yaml` are imported here to create the
//! case-name collision; each test then exercises `InvalidDocument`
//! construction in one of the two packages.
//!
//!   lyric test lyric-compiler/lyric/union_case_collision_self_test.l
@test_module
package Lyric.UnionCaseCollisionSelfTest

import Std.Core
import Std.Testing
import Std.Xml as Xml
import Std.Yaml as Yaml

// ── Xml side ─────────────────────────────────────────────────────────────────
test "Xml.parseXml with invalid input returns Err without MissingMethodException" {
  // Before #2899 this threw:
  //   MissingMethodException: Void Std.Yaml.YamlError_InvalidDocument..ctor(System.Object)
  // because InvalidDocument(message) inside parseXml resolved to the
  // Yaml ctor instead of the Xml ctor.  The fix ensures the same-package
  // candidate (Std.Xml.XmlError_InvalidDocument) wins.
  var errCount = 0
  match Xml.parseXml("hi") {
    case Ok(_) -> {
      panic("parseXml hi: expected Err, got Ok")
    }
    case Err(_) -> {
      errCount = errCount + 1
    }
  }
  assertEqualInt(errCount, 1, "parseXml returned Err(XmlError)")
}

test "Xml.parseXml with empty string returns Err" {
  var errCount = 0
  match Xml.parseXml("") {
    case Ok(_) -> {
      panic("parseXml empty: expected Err, got Ok")
    }
    case Err(_) -> {
      errCount = errCount + 1
    }
  }
  assertEqualInt(errCount, 1, "parseXml empty returned Err")
}

test "Xml.parseXml with well-formed XML returns Ok" {
  var okCount = 0
  match Xml.parseXml("<root/>") {
    case Ok(_) -> {
      okCount = okCount + 1
    }
    case Err(_) -> {
      panic("parseXml root: returned Err unexpectedly")
    }
  }
  assertEqualInt(okCount, 1, "parseXml returned Ok")
}

// ── Yaml side ────────────────────────────────────────────────────────────────
test "Yaml.parseYaml does not throw when Xml is also imported" {
  // The same fix also covers the Yaml side: InvalidDocument inside
  // parseYaml should resolve to YamlError_InvalidDocument.
  // We just verify no panic occurs.
  var reached = 0
  match Yaml.parseYaml("key: value") {
    case Ok(_) -> {
      reached = reached + 1
    }
    case Err(_) -> {
      reached = reached + 1
    }
  }
  assertEqualInt(reached, 1, "parseYaml completed without MissingMethodException")
}

test "Yaml.parseYaml with well-formed YAML returns Ok" {
  var okCount = 0
  match Yaml.parseYaml("key: value") {
    case Ok(_) -> {
      okCount = okCount + 1
    }
    case Err(_) -> {
      panic("parseYaml key-value: returned Err unexpectedly")
    }
  }
  assertEqualInt(okCount, 1, "parseYaml returned Ok")
}

// ── #2919: user-side construction of a colliding case name ──────────────────
// A bare `InvalidDocument(...)` with both packages imported is ambiguous and
// rejected (T0123, #6287 Phase B; covered in `typechecker_self_test.l`), so a
// user names the union.  These pin that each qualified construction builds
// its own union's case and that a qualified pattern matches it — the
// constructor and pattern lookups this file guards (#2899) must never pick the
// other package's same-named case.
test "Xml-qualified InvalidDocument constructs and matches Xml's case" {
  val e = Xml.XmlError.InvalidDocument(message = "oops")
  match e {
    case Xml.XmlError.InvalidDocument(msg) -> assertEqual(msg, "oops", "Xml's case carries its message")
    case _ -> panic("Xml.XmlError.InvalidDocument matched another case")
  }
}

test "Yaml-qualified InvalidDocument constructs and matches Yaml's case" {
  val e = Yaml.YamlError.InvalidDocument(message = "collision")
  var matched = 0
  match e {
    case Yaml.YamlError.InvalidDocument(msg) -> {
      assertEqual(msg, "collision", "Yaml's case carries its message")
      matched = matched + 1
    }
    case _ -> panic("Yaml.YamlError.InvalidDocument matched another case")
  }
  assertEqualInt(matched, 1, "exactly one arm matched")
}
