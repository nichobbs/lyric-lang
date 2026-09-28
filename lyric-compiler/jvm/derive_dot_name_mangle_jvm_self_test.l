//! derive_dot_name_mangle_jvm_self_test.l — executable regression test for
//! JVM classfile method-name mangling of dot-named functions (#7501).
//!
//! The JVM backend emits every `func Type.member(...)` — hand-written or
//! synthesised by `@generate`/`@derive` — as a STATIC method on the
//! declaring package's shared host class. Before this fix the classfile
//! method name was just the bare member name (`lowerFuncScoped` stripped
//! the `"TypeName."` prefix off `decl.name`), so two different types in the
//! same package declaring a same-named member with the same parameter list
//! collided on one bare name and descriptor:
//!   "java.lang.ClassFormatError: Duplicate method name ... with signature"
//! at class-load time. This blocked, among other things, any package with
//! two `@generate(Json)` records (each synthesises `fromJson(String)` and
//! `fromJsonElement(JsonElement)`), which in turn meant nested
//! `@generate(Json)` decoding never worked on the JVM (nesting needs two
//! records).
//!
//! The fix mangles a dot-named function's classfile name into
//! `TypeName$member` at both the definition site (`lowerFuncScoped`,
//! 06_items.l) and every call site that resolves a dot-named function
//! (`lowerMethodCall`'s three arms, 04_calls.l) — except a synthesised
//! per-type static (a distinct/range-subtype's `from`/`tryFrom`, a wire
//! factory's accessor) that already lives on its own dedicated, collision-
//! free class and keeps its plain method name.
//!
//! This module asserts, under `java`:
//!   • two `@generate(Json)` records in ONE package both load and decode,
//!     the second nested inside the first (exercises `fromJson` AND
//!     `fromJsonElement` on both types, and the nested nested-through-
//!     `fromJsonElement` nesting call itself, docs/decisions/
//!     D-progress-1002);
//!   • two hand-written dot-named functions with an IDENTICAL parameter
//!     list on two different types (`Widget.create(Int)` /
//!     `Gadget.create(Int)`) don't collide;
//!   • a decoded binding needs no explicit `: Person` annotation to match
//!     on and read a field of its `Ok` payload (the JVM erasure half of
//!     #7502: `collectDeriveFreeSigs` now eagerly resolves a derive-
//!     synthesised function's declared return-type generic args against
//!     its OWN declaring-package scope, exactly like a hand-written dot-
//!     named function's registration already did).
//!
//! Run in CI via the native `lyric test --target jvm` (compiled in-process
//! through the self-hosted `Jvm.Bridge`, `compileToJarBundled`, run under
//! `java`). Imports `Std.Json`, so it needs no `LYRIC_LOAD_COMPILER=1`.
//!
//!   lyric test --target jvm lyric-compiler/jvm/derive_dot_name_mangle_jvm_self_test.l
@test_module
package Lyric.DeriveDotNameMangleJvmSelfTest

import Std.Core
import Std.Json
import Std.Testing

// Two `@generate(Json)` records in one package (#7501): both synthesise a
// `fromJson(String)` and a `fromJsonElement(JsonElement)` static on this
// package's shared host class — the exact shape that collided before the
// `TypeName$member` mangle.
@generate(Json)
pub record Address {
  street: String
  city: String
}

@generate(Json)
pub record Person {
  name: String
  home: Address
}

// Two hand-written dot-named functions, same simple member name, same
// parameter list, on two different types — must not collide either.
record Widget {
  id: Int
}

func Widget.create(id: in Int): Widget {
  Widget(id = id)
}

record Gadget {
  id: Int
}

func Gadget.create(id: in Int): Gadget {
  Gadget(id = id)
}

// Exercises the JVM erasure half of #7502: `r`'s initialiser is a call to a
// derive-synthesised dot-named function with no explicit `: Result[Person,
// String]` annotation, and its `Ok` payload is read through a SEPARATE
// `match` (not a pattern bound directly off the call expression) — the
// shape that needs `r`'s recorded generic args, not the case-field
// `paramIdx` unboxing a `match` on the call itself already gets.
func firstNameOf(json: in String): String {
  val r = Person.fromJson(json)
  match r {
    case Ok(p) -> p.name
    case Err(e) -> "<err: " + e + ">"
  }
}

test "two @generate(Json) records in one package both load and decode nested" {
  val decoded = Person.fromJson("{\"name\": \"Ada\", \"home\": {\"street\": \"1 Main\", \"city\": \"Lima\"}}")
  match decoded {
    case Ok(p) -> {
      assertEqual(p.name, "Ada", "outer record's own field decodes")
      assertEqual(p.home.street, "1 Main", "nested record's field decodes via fromJsonElement")
      assertEqual(p.home.city, "Lima", "nested record's second field decodes via fromJsonElement")
    }
    case Err(e) -> assertTrue(false, "Person.fromJson unexpectedly failed: " + e)
  }
}

test "a directly-decoded nested record also loads (Address.fromJson)" {
  match Address.fromJson("{\"street\": \"9 Elm\", \"city\": \"Oslo\"}") {
    case Ok(a) -> assertEqual(a.city, "Oslo", "Address.fromJson decodes on its own")
    case Err(e) -> assertTrue(false, "Address.fromJson unexpectedly failed: " + e)
  }
}

test "hand-written same-arity dot-named functions on two types don't collide" {
  val w = Widget.create(7)
  val g = Gadget.create(9)
  assertEqualInt(w.id, 7, "Widget.create(7).id == 7")
  assertEqualInt(g.id, 9, "Gadget.create(9).id == 9")
}

test "an unannotated decoded binding still narrows for a later match+field read" {
  val name = firstNameOf("{\"name\": \"Mo\", \"home\": {\"street\": \"2 Elm\", \"city\": \"Rome\"}}")
  assertEqual(name, "Mo", "unannotated Result binding's Ok payload reads its field correctly")
}

test "malformed nested JSON still reports the field-level error" {
  match Person.fromJson("{\"name\": \"Zoe\", \"home\": 1}") {
    case Ok(_) -> assertTrue(false, "a non-object nested value was accepted")
    case Err(e) -> assertTrue(e == "missing field 'street'", "nested decode failure reports the expected message")
  }
}
