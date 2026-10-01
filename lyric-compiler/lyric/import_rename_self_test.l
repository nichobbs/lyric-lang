//! import_rename_self_test.l — renamed selective imports (#7564, D156).
//!
//! `import P.{f as g}` makes `g` a bare name for `P.f` and leaves `f`
//! itself hidden.  Every kind of item can be renamed: a function, a record
//! (whose constructor then builds `P`'s record, D155), a union (whose cases
//! are reached through the new name) and a value.  A parameter, local or
//! pattern binding named like the rename hides it only within its own
//! scope.
//!
//! Run on both targets:
//!   lyric test lyric-compiler/lyric/import_rename_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/import_rename_self_test.l
@test_module
package Lyric.ImportRenameSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String.{trim as strip, toUpper as shout}
import Std.JsonValue.{JsonField as Field, JsonValue as Json, writeValue as toJson}
import Std.Core.{Option as Maybe}

// The same simple name as Std.JsonValue's record: `Field` (the rename)
// must still build Std.JsonValue's.
record JsonField {
  label: String
}

func describe(v: in Json): String {
  return match v { case Json.JString(s) -> "string " + s; case Json.JNull -> "null"; case _ -> "other" }
}

test "a renamed function is called by its new name" {
  assertEqual(strip("  lyric  "), "lyric", "trim through its rename")
  assertEqual(shout(strip(" a ")), "A", "two renames composed")
}

test "a renamed record constructor builds the imported record" {
  val f = Field(name = "ok", value = Json.JBool(value = true))
  val fields: List[Field] = newList()
  fields.add(f)
  assertEqual(toJson(Json.JObject(fields = fields)), "{\"ok\":true}", "written as JSON")
  val mine = JsonField(label = "local")
  assertEqual(mine.label, "local", "the unrenamed name is this package's record")
}

test "a renamed union names its type, its cases and its pattern heads" {
  val v: Json = Json.JString(value = "x")
  assertEqual(describe(v), "string x", "constructed and matched through the rename")
  assertEqual(describe(Json.JNull), "null", "nullary case through the rename")
}

func firstOr(xs: in List[Int], fallback: in Int): Int {
  val head: Maybe[Int] = if xs.count > 0 { Maybe.Some(value = xs[0]) } else { Maybe.None }
  return match head { case Maybe.Some(v) -> v; case Maybe.None -> fallback }
}

test "a renamed generic type takes type arguments under its new name" {
  val xs: List[Int] = newList()
  assertEqualInt(firstOr(xs, 7), 7, "empty list: None")
  xs.add(3)
  assertEqualInt(firstOr(xs, 7), 3, "non-empty list: Some")
}

func shadowedByParameter(strip: in Int): Int {
  return strip + 1
}

test "a binding named like the rename hides it only in its own scope" {
  assertEqualInt(shadowedByParameter(41), 42, "the parameter is an Int")
  val before = strip(" a ")
  val strip = "local"
  assertEqual(before + strip, "alocal", "the import before the local, the local after it")
  val twice = { shout: String -> shout + shout }
  assertEqual(twice("b"), "bb", "a lambda parameter hides the rename in its body")
  assertEqual(shout("c"), "C", "and only there")
}
