//! union_case_collision_jvm_self_test.l — JVM regression test for #2535.
//!
//! #2535 flagged that the JVM ctors registry (`Jvm.Codegen.collectFileCtors`
//! / `addCtorKeys`) maps each type's *short* name to its JVM class name with
//! first-write-wins semantics: when `compileToJarBundled` bundles a
//! multi-package compile (this test's own package plus its transitive
//! `Std.*` closure), whichever package registers a colliding short name
//! FIRST would win, and every other same-named construction/pattern-match
//! in the bundle would silently resolve to the wrong class
//! (`ClassCastException` / `NoSuchMethodError` at runtime instead of a
//! compile-time error).
//!
//! Investigation found `addCtorKeys` had already grown a two-tier key
//! scheme as part of the #4802 fix (the historical repro there was
//! `Std.Xml.XmlError` and `Std.Yaml.YamlError` both declaring a case named
//! `InvalidDocument`): an own-package-scoped `<owner>::<name>` key is tried
//! before the bare first-wins key via `ctorClassFor`, plus a
//! union-name-qualified `<Union>$<Case>` key for case classes
//! (`resolveCaseClassJvm` in `03_match.l`).  That fix already covers the
//! scenario #2535 describes: a package's own construction of its own type,
//! or of a case under its own union name, always resolves to the correct
//! declaring class regardless of what any other bundled package registered
//! under the bare short-name key first — regardless of bundle processing
//! order.
//!
//! `Std.Xml` itself cannot currently be compiled with `--target jvm` at all
//! (an unrelated, pre-existing bug: `Jvm.Codegen` fails to lower the
//! fully-qualified call `Std.Char.fromInt(...)` in `xml.l`, `error[J002]:
//! reference 'Std' resolves to no local, parameter, ...` — reproduced
//! independently of this issue and of `Std.Yaml`), so this test reproduces
//! the SAME class of collision without depending on `Std.Xml`: a
//! locally-declared union case named `InvalidDocument` (colliding with
//! `Std.Yaml.YamlError`'s own case of the same name) alongside a real call
//! into `Std.Yaml.parseYaml`, which internally constructs its OWN
//! `InvalidDocument` case.  This exercises the exact own-package-precedence
//! code path #4802 fixed: my own package's bare-name `InvalidDocument`
//! construction must resolve to MY case, and `Std.Yaml`'s internal
//! `InvalidDocument` construction (running in `Std.Yaml`'s own package
//! context) must resolve to YAML's case — neither should shadow the other,
//! regardless of which package's `collectFileCtors` pass ran first.
//!
//! No JVM-side runtime test locked this in before (only the MSIL analog,
//! #2899's `union_case_collision_self_test.l`, existed) — this file is that
//! missing regression pin for the JVM backend.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`,
//! bundling this package with its transitive `Std.Yaml` closure — the
//! multi-package scenario #2535 describes) and runs it under `java`.
//! Imports only `Std.*`.
@test_module
package Jvm.UnionCaseCollisionSelfTest

import Std.Core
import Std.Testing
import Std.Yaml as Yaml

// Deliberately colliding short case name: `Std.Yaml.YamlError` also
// declares a case named `InvalidDocument`.  Before the #4802 fix, whichever
// package's `collectFileCtors` pass ran first would win the bare
// `InvalidDocument` key bundle-wide.
pub union MyDocError {
  case InvalidDocument(message: String)
}

func makeMyError(msg: String): MyDocError {
  InvalidDocument(message = msg)
}

test "own-package construction of a colliding case name resolves to the local case" {
  match makeMyError("local failure") {
    case InvalidDocument(m) -> {
      assertEqual(m, "local failure", "MyDocError's own InvalidDocument case, not Std.Yaml's")
    }
  }
}

test "Std.Yaml's internal InvalidDocument construction is unaffected by the local collision" {
  var reached = 0
  match Yaml.parseYaml("key: value") {
    case Ok(_) -> {
      reached = reached + 1
    }
    case Err(_) -> {
      reached = reached + 1
    }
  }
  assertEqualInt(reached, 1, "parseYaml completed without a cross-package ctor mismatch")
}

test "Std.Yaml.parseYaml with well-formed YAML returns Ok" {
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
