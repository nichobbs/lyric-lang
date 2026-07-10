@test_module
package Lyric.ImportExternSelfTest

import Std.Core
import Std.Math as Math
import Std.Testing
import extern System.{Math as SystemMath, Int32 as NetInt32, Int64 as NetInt64, String as NetString, Environment as NetEnv}
import extern System.Text.{Encoding, StringBuilder}
import extern System.Diagnostics.{Stopwatch}
import extern System.Text.RegularExpressions.{Regex, RegexOptions}

test "Math.Max binds the int overload via import extern" {
  assertEqualInt(SystemMath.Max(2, 5), 5, "Max(2,5)")
  assertEqualInt(SystemMath.Max(10, 3), 10, "Max(10,3)")
}

test "Math.Min binds the int overload via import extern" {
  assertEqualInt(SystemMath.Min(10, 3), 3, "Min(10,3)")
  assertEqualInt(SystemMath.Min(2, 5), 2, "Min(2,5)")
}

test "Math.Abs binds the int overload via import extern" {
  assertEqualInt(SystemMath.Abs(-7), 7, "Abs(-7)")
  assertEqualInt(SystemMath.Abs(42), 42, "Abs(42)")
}

test "Math.PI literal R8 constant inlines via member access" {
  val pi = SystemMath.PI
  assertTrue(pi > 3.141592, "PI lower bound")
  assertTrue(pi < 3.141593, "PI upper bound")
  val tau = SystemMath.Tau
  assertTrue(tau > 6.283185, "Tau lower bound")
  assertTrue(tau < 6.283186, "Tau upper bound")
}

test "Std.Math.pi routes the R8 constant through @externTarget" {
  // Regression: the @externTarget static-field path used to fall through to
  // `ldsfld` for a non-Int32 literal constant, which faults at run time with
  // MissingFieldException (a literal field has no storage).
  val pi = Math.pi()
  assertTrue(pi > 3.141592, "Std.Math.pi lower bound")
  assertTrue(pi < 3.141593, "Std.Math.pi upper bound")
}

test "Int32.MaxValue literal I4 constant inlines via member access" {
  assertEqualInt(NetInt32.MaxValue, 2147483647, "Int32.MaxValue")
}

test "Int64.MaxValue literal I8 constant inlines via member access" {
  assertEqualLong(NetInt64.MaxValue, 9223372036854775807i64, "Int64.MaxValue")
}

test "String.Empty static field reads via ldsfld" {
  assertEqual(NetString.Empty, "", "String.Empty")
}

test "Stopwatch.Frequency static long field reads via ldsfld" {
  assertTrue(Stopwatch.Frequency > 0i64, "Stopwatch.Frequency > 0")
}

test "static property getter resolves via member access and call form" {
  val enc = Encoding.UTF8
  assertEqual(enc.BodyName, "utf-8", "UTF8.BodyName member form")
  val enc2 = Encoding.UTF8()
  assertEqual(enc2.BodyName(), "utf-8", "UTF8().BodyName() call form")
}

test "instance property get, set, and compound set on a constructed extern object" {
  val sb = StringBuilder.new()
  sb.Append("hello")
  assertEqualInt(sb.Length, 5, "Length member form after Append")
  assertEqualInt(sb.Length(), 5, "Length() call form")
  sb.Length = 2
  assertEqualInt(sb.Length, 2, "Length after set")
  assertEqual(sb.ToString(), "he", "content after Length set")
  val sb2 = StringBuilder.new()
  sb2.Append("worlds")
  sb2.Length -= 1
  assertEqual(sb2.ToString(), "world", "content after compound Length -= 1")
}

test "static property set and get round-trips" {
  NetEnv.ExitCode = 42
  assertEqualInt(NetEnv.ExitCode, 42, "ExitCode after set")
  NetEnv.ExitCode += 1
  assertEqualInt(NetEnv.ExitCode, 43, "ExitCode after compound +=")
  NetEnv.ExitCode = 0
  assertEqualInt(NetEnv.ExitCode, 0, "ExitCode reset")
}

test "enum constants resolve and pass to a BCL method" {
  assertTrue(Regex.IsMatch("Hello World", "hello", RegexOptions.IgnoreCase), "IgnoreCase matches")
  assertFalse(Regex.IsMatch("Hello World", "hello", RegexOptions.None), "None does not match")
}
