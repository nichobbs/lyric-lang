//! qualified_ctor_self_test.l — qualified constructor calls (D159).
//!
//! A constructor may be written qualified by its package's path or alias
//! (`Std.JsonValue.JsonField(...)`, `J.JsonField(...)`) and a union case by
//! its union (`J.JsonValue.JString(...)`, `Token.JNull`).  The written
//! qualifier decides: this package declares a record and union cases with
//! the same simple names as `Std.JsonValue`'s, and a qualified call must
//! still build the qualifier's type.  Before D159 the MSIL backend built
//! the local same-named record instead, which failed at run time with
//! `InvalidProgramException`.
//!
//! Run on both targets:
//!   lyric test lyric-compiler/lyric/qualified_ctor_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/qualified_ctor_self_test.l
@test_module
package Lyric.QualifiedCtorSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.JsonValue as J

record JsonField {
  label: String
}

union Token {
  case JString(text: String)
  case JNull
}

func tokenText(t: in Token): String {
  return match t { case JString(s) -> "text " + s; case JNull -> "null token" }
}

test "a package-qualified record constructor builds that package's record" {
  val f = Std.JsonValue.JsonField(name = "a", value = J.JsonValue.JNull)
  assertEqual(f.name, "a", "the Std.JsonValue field")
  val local = JsonField(label = "mine")
  assertEqual(local.label, "mine", "the unqualified name is still the local record")
}

test "an alias-qualified record constructor builds the aliased package's record" {
  val f = J.JsonField(name = "b", value = J.JsonValue.JBool(value = true))
  val fields: List[J.JsonField] = newList()
  fields.add(f)
  assertEqual(J.writeValue(J.JsonValue.JObject(fields = fields)), "{\"b\":true}", "written as a JSON object")
}

test "a union-qualified case builds the qualifier's case" {
  val v = J.JsonValue.JString(value = "x")
  match v {
    case JString(s) -> assertEqual(s, "x", "the JsonValue case")
    case _ -> assertTrue(false, "expected JString")
  }
  assertEqual(J.writeValue(J.JsonValue.JNull), "null", "the nullary JsonValue case")
  assertEqual(tokenText(Token.JString(text = "y")), "text y", "the local union's case")
  assertEqual(tokenText(Token.JNull), "null token", "the local nullary case")
}
