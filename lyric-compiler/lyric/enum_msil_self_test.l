//! enum_msil_self_test.l — #3196: Lyric enums on the self-hosted MSIL backend.
//!
//! Covers the two defects that made `Std.Log` (enum `LogLevel` followed by
//! record `LogField`) fault the JIT, plus the ordinal-int enum value model:
//!
//!   1. FieldDef-row accounting: an enum emits 1 (`value__`) + N case
//!      FieldDef rows, so every record/union declared AFTER an enum in the
//!      same package had its field tokens off by (1 + N) — `ldfld` bound the
//!      enum's rows and the JIT rejected the method as an invalid program.
//!   2. Enum values are I4 ordinals end-to-end (F#-emitter parity): a case
//!      reference emits `ldc.i4 <ordinal>`, a `case X ->` pattern compares
//!      ordinals, and enum-typed signature positions encode I4 — a
//!      CLASS-flavored reference to the enum TypeDef (a value type) is a
//!      loader-level "value type mismatch".
//!
//! Run in CI via native `lyric test --target dotnet` (in-process through the
//! self-hosted `Msil.Bridge`).  Imports only `Std.*`.
@test_module
package Lyric.EnumMsilSelfTest

import Std.Core
import Std.Testing

enum Color {
  case Red
  case Green
  case Blue
}

// Declared AFTER the enum so its field tokens regress if the enum's
// FieldDef rows are ever uncounted again (#3196 defect 1).
record KV {
  key: String
  value: String
}

record Tagged {
  c: Color
  label: String
}

func colorName(c: in Color): String {
  match c {
    case Red -> "red"
    case Green -> "green"
    case Blue -> "blue"
  }
}

// A second enum (distinct case names — enum cases share module scope, so two
// in-module enums can't reuse a name) so a qualified value resolves against the
// right type's ordinal table when more than one enum is registered (#3346).
enum Hue {
  case Warm
  case Cool
}

func hueName(h: in Hue): String {
  match h {
    case Warm -> "warm"
    case Cool -> "cool"
  }
}

// Returns a qualified enum value from expression position (#3344).
func pick(b: in Bool): Color {
  if b {
    Color.Green
  } else {
    Color.Blue
  }
}

// The Std.Log.formatFields shape: a loop over slice[Record] with field
// reads, where the record was declared after an enum.
func fmt(fields: in slice[KV]): String {
  if fields.length == 0 {
    return ""
  }
  var text = ""
  var i = 0
  while i < fields.length {
    val f = fields[i]
    val pair = f.key + "=" + f.value
    if i == 0 {
      text = " " + pair
    } else {
      text = text + " " + pair
    }
    i += 1
  }
  return text
}

test "enum cases are distinct ordinals and match correctly" {
  assertEqual(colorName(Red), "red", "Red")
  assertEqual(colorName(Green), "green", "Green")
  assertEqual(colorName(Blue), "blue", "Blue")
}

test "enum value flows through a local and a record field" {
  val c = Green
  assertEqual(colorName(c), "green", "via local")
  val t = Tagged(c = Blue, label = "x")
  assertEqual(colorName(t.c), "blue", "via record field")
  assertEqual(t.label, "x", "sibling field after enum-typed field")
}

test "qualified enum value in argument position (#3344)" {
  // `Color.Red` parses as EMember(EPath["Color"], "Red"); it must lower to the
  // ordinal, not evaluate the bare type name as a value (which NREs).
  assertEqual(colorName(Color.Red), "red", "Color.Red as arg")
  assertEqual(colorName(Color.Green), "green", "Color.Green as arg")
  assertEqual(colorName(Color.Blue), "blue", "Color.Blue as arg")
}

test "qualified enum value as match scrutinee (#3344)" {
  val r = match Color.Green { case Red -> "r"; case Green -> "g"; case Blue -> "b" }
  assertEqual(r, "g", "Color.Green scrutinee")
}

test "qualified enum value returned from expression position (#3344)" {
  assertEqual(colorName(pick(true)), "green", "returned Color.Green")
  assertEqual(colorName(pick(false)), "blue", "returned Color.Blue")
}

test "qualified value resolves against the named enum's ordinals (#3346)" {
  // Color.Green is ordinal 1; Hue.Warm is ordinal 0.  Each qualified value must
  // resolve against its own enum's ordinal table even with two enums in scope.
  assertEqual(hueName(Hue.Warm), "warm", "Hue.Warm")
  assertEqual(hueName(Hue.Cool), "cool", "Hue.Cool")
  assertEqual(colorName(Color.Green), "green", "Color.Green alongside Hue")
}

test "record field tokens are correct after a preceding enum" {
  val xs = [KV(key = "a", value = "1"), KV(key = "b", value = "2")]
  assertEqual(fmt(xs), " a=1 b=2", "formatFields shape")
  val ys: slice[KV] = []
  assertEqual(fmt(ys), "", "empty slice early return")
}
