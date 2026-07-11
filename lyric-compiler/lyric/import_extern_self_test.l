@test_module
package Lyric.ImportExternSelfTest

import Std.Core
import Std.Math as Math
import Std.Testing
import Std.Uuid
import extern System.{Math as SystemMath, Int32 as NetInt32, Int64 as NetInt64, String as NetString, Environment as NetEnv, TimeSpan, Guid, DateTime, Convert}
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

test "Std.Math.pi inlines the R8 constant through the stdlib kernel" {
  // Regression: a literal constant used to fall through to `ldsfld` for a
  // non-Int32 literal, which faults at run time with MissingFieldException
  // (a literal field has no storage).  Std.MathHost now reads Math.PI via
  // extern-type member access (auto-FFI const inlining) rather than an
  // @externTarget wrapper; the runtime value must be unchanged.
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

test "value-type instance methods dispatch through ldloca + call" {
  val ts = TimeSpan.FromMinutes(5.0)
  // reference-type (String) return
  assertEqual(ts.ToString(), "00:05:00", "TimeSpan.ToString()")
  // value-type return, then a chained instance call on that struct result
  val neg = ts.Negate()
  assertEqual(neg.ToString(), "-00:05:00", "Negate() value-type return")
  // primitive (Int32) return
  val g = Guid.new("550e8400-e29b-41d4-a716-446655440000")
  val g2 = Guid.new("550e8400-e29b-41d4-a716-446655440000")
  assertEqualInt(g.GetHashCode(), g2.GetHashCode(), "GetHashCode() primitive return")
}

test "value-type instance property gets via member access and call form" {
  val ts = TimeSpan.FromMinutes(5.0)
  assertTrue(ts.TotalMinutes > 4.999, "TotalMinutes member form lower bound")
  assertTrue(ts.TotalMinutes < 5.001, "TotalMinutes member form upper bound")
  assertTrue(ts.TotalSeconds() > 299.9, "TotalSeconds() call form lower bound")
  assertTrue(ts.TotalSeconds() < 300.1, "TotalSeconds() call form upper bound")
  val dt = DateTime.new(2024, 3, 15)
  assertEqualInt(dt.Day, 15, "Day property on a constructed struct")
}

test "value-type .new(args) constructs via newobj (Q48-004)" {
  val ts = TimeSpan.new(1, 2, 3)
  assertEqual(ts.ToString(), "01:02:03", "TimeSpan.new(int,int,int)")
  val g = Guid.new("550e8400-e29b-41d4-a716-446655440000")
  assertEqual(g.ToString(), "550e8400-e29b-41d4-a716-446655440000", "Guid.new(string)")
  val dt = DateTime.new(2024, 3, 15)
  val dt2 = dt.AddDays(10.0)
  assertEqualInt(dt2.Day, 25, "AddDays on a .new()-constructed struct")
}

test "zero-arg .new() on a value type yields the zero-initialised default" {
  val z = TimeSpan.new()
  assertEqual(z.ToString(), "00:00:00", "default TimeSpan")
  val zg = Guid.new()
  assertEqual(zg.ToString(), "00000000-0000-0000-0000-000000000000", "default (nil) Guid")
}

test "extern struct equality boxes both operands for Object.Equals" {
  val a = Guid.new("550e8400-e29b-41d4-a716-446655440000")
  val b = Guid.new("550e8400-e29b-41d4-a716-446655440000")
  val c = Guid.new("00000000-0000-0000-0000-000000000001")
  assertTrue(a == b, "equal guids compare equal")
  assertFalse(a == c, "different guids compare unequal")
  assertTrue(a != c, "!= on different guids")
  assertFalse(a != b, "!= on equal guids")
}

test "extern struct interpolation boxes before ToString" {
  val g = Guid.new("550e8400-e29b-41d4-a716-446655440000")
  assertEqual("id=${g}", "id=550e8400-e29b-41d4-a716-446655440000", "interpolated struct")
  val ts = TimeSpan.FromMinutes(5.0)
  assertEqual("span=${ts}", "span=00:05:00", "interpolated TimeSpan")
}

test "slice[Byte] argument resolves Convert.ToBase64String(byte[])" {
  val bs: slice[Byte] = [77u8, 97u8, 110u8]
  assertEqual(Convert.ToBase64String(bs), "TWFu", "ToBase64String(byte[]) on 'Man'")
}

test "slice[String] argument resolves String.Join(string, string[])" {
  val parts: slice[String] = ["a", "b", "c"]
  assertEqual(NetString.Join("-", parts), "a-b-c", "Join(string, string[])")
}

test "extern struct flows through uniform-ABI generic calls (#5196)" {
  val parsed = parseUuidOpt("550e8400-e29b-41d4-a716-446655440000")
  val u = unwrapOr(parsed, nilUuid())
  assertEqual(uuidToString(u), "550e8400-e29b-41d4-a716-446655440000", "unwrapOr on Option[Uuid]")
  assertTrue(isSome(parsed), "isSome on Option[Uuid]")
  assertTrue(isNone(parseUuidOpt("not-a-uuid")), "isNone on unparseable input")
  val fallback = unwrapOr(parseUuidOpt("not-a-uuid"), nilUuid())
  assertEqual(uuidToString(fallback), "00000000-0000-0000-0000-000000000000", "unwrapOr default path")
}
