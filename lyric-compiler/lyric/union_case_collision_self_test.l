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

// ── #2919: explicit user-side construction of a colliding case name ──────────
// The issue's originally-suggested regression case — an explicitly-typed
// binding like `val e: Xml.XmlError = InvalidDocument(message = "oops")` — is
// still blocked by a pre-existing, unrelated type-checker gap: the type
// checker resolves the bare name `InvalidDocument` independently of the
// declared binding type (context-free `inferExpr`), so an explicit type
// annotation that disagrees with whichever case it happened to pick emits
// T0060 before the emitter's `pickCaseFqnByScope` import-priority branch is
// ever reached. That architectural gap (bidirectional/context-aware
// constructor-name checking) is out of scope for a test-only change and
// remains tracked separately.
//
// However, a DIFFERENT construction shape — a bare, UNqualified,
// UNannotated construction (`InvalidDocument(message = "oops")`, no `Xml.`/
// `Yaml.` qualifier and no declared `val` type) — does not hit T0060 (nothing
// to disagree with) and genuinely exercises `pickCaseFqnByScope`'s
// import-priority branch at the construction call site: with no same-package
// prefix match, `unionCaseCtorByName["InvalidDocument"]` has two candidates
// (`Std.Xml.XmlError_InvalidDocument` and `Std.Yaml.YamlError_InvalidDocument`)
// and the resolver falls through to the import-scan loop.  The tests below
// pin the resulting resolution as a deterministic, observable regression
// guard: they match the bare-constructed value against explicitly-qualified
// patterns for BOTH unions so a future change that flips (or randomizes)
// which candidate wins is caught, rather than silently passing because both
// cases share the same `message: String` field shape.
test "bare unqualified InvalidDocument() constructs Xml's case (import-priority resolution)" {
  val e = InvalidDocument(message = "oops")
  match e {
    case Xml.XmlError.InvalidDocument(_) -> assertEqualInt(1, 1, "resolved to Std.Xml.XmlError's case")
    case Yaml.YamlError.InvalidDocument(_) -> panic("resolved to Std.Yaml.YamlError's case instead of Std.Xml.XmlError's")
    case _ -> panic("resolved to neither colliding union's case")
  }
}

test "bare unqualified InvalidDocument() match arm resolves the same way as construction" {
  // Constructs AND matches with the bare (unqualified) name on both sides —
  // this is self-consistent by construction (both resolve through the same
  // `unionCaseCtorByName`/`pickCaseFqnByScope` lookup), but it pins that the
  // bare match arm does not panic with `MissingFieldException` at runtime,
  // which was the original #2899 failure mode this whole file guards.
  val e = InvalidDocument(message = "collision")
  var matched = 0
  match e {
    case InvalidDocument(msg) -> {
      assertEqual(msg, "collision", "the matched case's field carries the constructed value")
      matched = matched + 1
    }
    case _ -> panic("bare InvalidDocument() failed to match its own bare-constructed value")
  }
  assertEqualInt(matched, 1, "exactly one arm matched")
}
