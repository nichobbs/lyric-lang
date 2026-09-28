//! propagate_dot_named_bind_jvm_self_test.l — executable regression test
//! (#7631) for an unannotated `val p = <call>?` whose bound value is then read
//! through a field or method (`p.name`), on `--target jvm`.
//!
//! `?` never reaches JVM codegen: `Lyric.Propagate` rewrites
//! `val p = f(x)?` into `val p = match f(x) { case Ok(v) -> v; case Err(e)
//! -> { return Err(e) } }` (the scrutinee wrapped in an implicit `await`
//! unless the call is a bare same-file sync function).  `p`'s JVM type is
//! the match's first arm type, i.e. the `Ok`/`Some` payload's class, which
//! `lowerPatternBind` recovers from the scrutinee's instantiation via
//! `Jvm.Codegen.scrutineeGenericArgs`.
//!
//! The gap: for a type-associated (dot-named) function that is
//! package-private (`func Person.parse(...)`, no `pub`), the only
//! `funcSigs` registrations are the package-scoped `<pkg>::Person.parse`
//! keys; the bundle-wide bare `Person.parse` key is reserved for
//! `pub`/`internal` functions (#6853).  `scrutineeGenericArgs` looked up
//! only the bare key, recovered no instantiation, bound `p` as erased
//! `Object`, and `p.name` failed with `error[J007]: member 'name' cannot be
//! resolved on an erased (statically Object) receiver`.  The direct
//! `match Person.parse(s) { case Ok(p) -> p.name }` form failed the same
//! way.  The fix gives the lookup the scoped-key-first precedence that the
//! call site itself (`lowerMethodCall`, #6664) already uses.
//!
//! Cases: `?` on `Result`- and `Option`-returning package-private
//! dot-named functions, the direct-match form, a `@generate(Json)`
//! record's synthesised `Person.fromJson(json)?`, and `?` on same-file free
//! functions (never broken; guards against regressing them).
//!
//! Run in CI via native `lyric test` on both targets: `--target jvm` is the
//! load-bearing run; `--target dotnet` checks parity.  Imports only `Std.*`.
//!
//!   lyric test --target jvm    lyric-compiler/jvm/propagate_dot_named_bind_jvm_self_test.l
//!   lyric test --target dotnet lyric-compiler/jvm/propagate_dot_named_bind_jvm_self_test.l
@test_module
package Lyric.PropagateDotNamedBindJvmSelfTest

import Std.Core
import Std.Json
import Std.Testing

record Person {
  name: String
  age: Int
}

@generate(Json)
record Pet {
  name: String
  legs: Int
}

func Person.parse(s: in String): Result[Person, String] {
  if s == "" {
    Err("empty")
  } else {
    Ok(Person(name = s, age = s.length))
  }
}

func Person.label(self: in Person): String {
  self.name + "/" + toString(self.age)
}

func Person.find(s: in String): Option[Person] {
  if s == "" {
    None
  } else {
    Some(Person(name = s, age = 7))
  }
}

func parsePerson(s: in String): Result[Person, String] {
  if s == "" {
    Err("empty")
  } else {
    Ok(Person(name = s, age = 42))
  }
}

func findPerson(s: in String): Option[Person] {
  if s == "" {
    None
  } else {
    Some(Person(name = s, age = 3))
  }
}

func dotResultName(s: in String): Result[String, String] {
  val p = Person.parse(s)?
  Ok(p.label())
}

func dotOptionAge(s: in String): Option[Int] {
  val p = Person.find(s)?
  Some(p.age + 1)
}

func dotDirectMatchName(s: in String): Result[String, String] {
  match Person.parse(s) {
    case Ok(p) -> Ok(p.name)
    case Err(e) -> Err(e)
  }
}

func jsonPetLegs(json: in String): Result[Int, String] {
  val p = Pet.fromJson(json)?
  Ok(p.legs * 10)
}

func freeResultAge(s: in String): Result[Int, String] {
  val p = parsePerson(s)?
  Ok(p.age)
}

func freeOptionName(s: in String): Option[String] {
  val p = findPerson(s)?
  Some(p.name + "!")
}

test "? on a package-private dot-named Result function binds the payload type" {
  match dotResultName("ann") {
    case Ok(n) -> assertEqual(n, "ann/3", "Ok payload method call")
    case Err(e) -> assertTrue(false, "unexpected Err: " + e)
  }
  match dotResultName("") {
    case Ok(_) -> assertTrue(false, "expected the Err to propagate")
    case Err(e) -> assertEqual(e, "empty", "Err propagated")
  }
}

test "? on a package-private dot-named Option function binds the payload type" {
  match dotOptionAge("bob") {
    case Some(a) -> assertEqualInt(a, 8, "Some payload field read")
    case None -> assertTrue(false, "unexpected None")
  }
  match dotOptionAge("") {
    case Some(_) -> assertTrue(false, "expected None to propagate")
    case None -> assertTrue(true, "None propagated")
  }
}

test "direct match on a package-private dot-named call binds the payload type" {
  match dotDirectMatchName("cy") {
    case Ok(n) -> assertEqual(n, "cy", "direct-match payload field read")
    case Err(e) -> assertTrue(false, "unexpected Err: " + e)
  }
}

test "? on a @generate(Json) record's fromJson binds the payload type" {
  match jsonPetLegs("{\"name\":\"rex\",\"legs\":4}") {
    case Ok(n) -> assertEqualInt(n, 40, "decoded payload field read")
    case Err(e) -> assertTrue(false, "unexpected Err: " + e)
  }
  match jsonPetLegs("not json") {
    case Ok(_) -> assertTrue(false, "expected the decode Err to propagate")
    case Err(_) -> assertTrue(true, "decode Err propagated")
  }
}

test "? on same-file free functions binds the payload type" {
  match freeResultAge("dee") {
    case Ok(a) -> assertEqualInt(a, 42, "Result payload field read")
    case Err(e) -> assertTrue(false, "unexpected Err: " + e)
  }
  match freeOptionName("eve") {
    case Some(n) -> assertEqual(n, "eve!", "Option payload field read")
    case None -> assertTrue(false, "unexpected None")
  }
}
