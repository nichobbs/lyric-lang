//! yaml_stdlib_field_abi_self_test.l — regression test for #5010: a
//! `Std.*` stdlib union case or record whose field forward-references
//! another type declared later in the same package — e.g. `Std.Yaml`'s
//! `YamlValue`'s `YMapping(pairs: List[YamlPair])` case referencing
//! `YamlPair`, which itself has `value: YamlValue` referencing back (mutual
//! recursion) — used to have that field's cross-package MemberRef signature
//! silently degraded to `System.Object` instead of the real type.
//!
//! Root cause (`lyric-compiler/msil/codegen.l`,
//! `registerStdlibTypeItem`/`registerStdlibArtifactTokens`):
//!   1. Stdlib union-case field signatures were built with the
//!      context-free `buildFieldSig` (which cannot resolve a cross-assembly
//!      TypeRef by name and always degrades reference types to Object)
//!      instead of the context-aware `buildFieldSigWithCtx` used by every
//!      other cross-package field-registration path.
//!   2. Even after fixing (1), stdlib type registration was a single
//!      combined pass that registered a type's own TypeRef and immediately
//!      baked its field signatures — so a field naming a type declared
//!      LATER in the same package (or mutually recursive with it) baked its
//!      signature before that type's TypeRef existed, degrading to Object
//!      the same way.
//!
//! Both are fixed by splitting stdlib type registration into two full
//! sub-passes across every package (`registerStdlibTypeItemRefs` then
//! `registerStdlibTypeItemMembers`), mirroring the already-correct two-pass
//! structure `registerRestoredArtifactTokens` uses for non-stdlib packages.
//!
//! A degraded field signature does not fail to *compile* — NativeAOT's
//! whole-program linking (the release tarball) resolves the field by
//! (owner, name) regardless of the caller's stale cached signature, masking
//! the bug — but a framework-dependent, JIT-loaded assembly (the published
//! `lyric` NuGet global tool) throws `System.MissingFieldException: Field
//! not found` the moment the field is read, since the CLR's field-binding
//! validates the caller's signature against the real FieldDef.  This test
//! reproduces the crash directly: `lyric test` compiles the module
//! in-process through `Msil.Bridge` (a JIT-executed framework-dependent
//! path, precisely where the degraded signature used to fault) and asserts
//! real values, not just that compilation succeeds.
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.YamlStdlibFieldAbiSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Yaml as Yaml

test "asMapping: reading YamlPair.key/.value off a parsed YMapping does not crash and returns correct values (#5010)" {
  val parsed = Yaml.parseJson("{\"name\": \"lyric\", \"count\": 3}")
  match parsed {
    case Err(_) -> assertTrue(false, "parseJson should not fail on valid JSON")
    case Ok(root) -> {
      match Yaml.asMapping(root) {
        case None -> assertTrue(false, "root should parse as a mapping")
        case Some(pairs) -> {
          assertEqualInt(pairs.count, 2, "mapping has two entries")
          var i = 0
          var sawName = false
          var sawCount = false
          while i < pairs.count {
            val p = pairs[i]
            if p.key == "name" {
              sawName = true
              match Yaml.asString(p.value) {
                case Some(s) -> assertEqual(s, "lyric", "name value")
                case None -> assertTrue(false, "name value should be a string")
              }
            } else if p.key == "count" {
              sawCount = true
              match Yaml.asInt(p.value) {
                case Some(n) -> assertEqualLong(n, 3, "count value")
                case None -> assertTrue(false, "count value should be an int")
              }
            }
            i = i + 1
          }
          assertTrue(sawName, "saw the 'name' pair")
          assertTrue(sawCount, "saw the 'count' pair")
        }
      }
    }
  }
}

test "getField: nested mapping access also exercises the same cross-package field read" {
  val parsed = Yaml.parseJson("{\"outer\": {\"inner\": \"value\"}}")
  match parsed {
    case Err(_) -> assertTrue(false, "parseJson should not fail on valid JSON")
    case Ok(root) -> {
      match Yaml.getField(root, "outer") {
        case None -> assertTrue(false, "outer field should be present")
        case Some(outer) -> {
          match Yaml.getString(outer, "inner") {
            case Some(s) -> assertEqual(s, "value", "nested inner value")
            case None -> assertTrue(false, "inner should be a string field")
          }
        }
      }
    }
  }
}
