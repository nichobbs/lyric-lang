//! format_builtin_self_test.l — dual-target runtime regression test for the
//! `format1`-`format4` builtins (#7840).
//!
//! Every arity lowers, in `Lyric.Pipeline`, to `Std.String.formatArgs` over
//! its arguments stringified as `toString` stringifies them, so both targets
//! share one placeholder grammar: `{n}` substitutes argument `n`, `{{` and
//! `}}` are literal braces, an argument no placeholder names is ignored, and
//! any other brace or a placeholder with no argument panics.  Before the fix
//! the JVM builtins returned the template unformatted and dotnet called
//! `String.Format`, and `format3`/`format4` had no type-checker signature.
//! The cases cover each arity, escaping, missing and extra placeholders,
//! `UInt`/`ULong` arguments at and above the sign bit (#7812), a
//! non-literal template and argument evaluation order (`Byte` arguments are
//! in `byte_stringify_self_test.l`).
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/format_builtin_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/format_builtin_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.  The
//! native target is covered by `llvm_stdlib_self_test.l`.
@test_module
package Lyric.FormatBuiltinSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Counts {
  small: UInt
  big: ULong
}

record Box[T] {
  value: T
}

type Tally = UInt range 0u32 ..= 4294967295u32

func bigUInt(): UInt {
  4294967295u32
}

func bigULong(): ULong {
  18446744073709551615u64
}

func logged(log: in List[Int], v: in Int): Int {
  log.add(v)
  v
}

test "format1 substitutes its argument" {
  assertEqual(format1("{0}", 42), "42", "Int")
  assertEqual(format1("x={0};", "y"), "x=y;", "String")
  assertEqual(format1("{0}", true), "true", "Bool")
  assertEqual(format1("{0}", 'c'), "c", "Char")
  assertEqual(format1("{0}", 2.5), "2.5", "Double")
  assertEqual(format1("{0}", -7i64), "-7", "Long")
  assertEqual(format1("{0}{0}", 1), "11", "repeated placeholder")
  assertEqual(format1("", 1), "", "empty template")
}

test "format2 substitutes both arguments in placeholder order" {
  assertEqual(format2("{0} {1}", "a", 2), "a 2", "in order")
  assertEqual(format2("{1}{0}{1}", "a", "b"), "bab", "reordered and repeated")
  assertEqual(format2("{0}/{1}", 0, 127), "0/127", "two Ints")
}

test "format3 substitutes three arguments" {
  assertEqual(format3("{0}-{1}-{2}", 1, "two", 3.5), "1-two-3.5", "mixed types")
  assertEqual(format3("{2}{1}{0}", "a", "b", "c"), "cba", "reversed")
}

test "format4 substitutes four arguments" {
  assertEqual(format4("{0},{1},{2},{3}", 1, 2, 3, 4), "1,2,3,4", "in order")
  assertEqual(format4("{3}{2}{1}{0}", 'a', 'b', 'c', 'd'), "dcba", "reversed")
}

test "doubled braces are literal braces" {
  assertEqual(format1("{{{0}}}", 7), "{7}", "escaped braces around a placeholder")
  assertEqual(format1("{{0}}", 7), "{0}", "an escaped placeholder is not substituted")
  assertEqual(format2("{{}} {0} {{ {1} }}", 1, 2), "{} 1 { 2 }", "escapes between placeholders")
  assertEqual(format1("}}{{", 0), "}{", "escapes only")
}

test "an argument no placeholder names is ignored" {
  assertEqual(format1("no placeholders", 1), "no placeholders", "format1")
  assertEqual(format2("{1}", "unused", "used"), "used", "format2")
  assertEqual(format3("{0}", 1, 2, 3), "1", "format3")
  assertEqual(format4("{3}", 1, 2, 3, 4), "4", "format4")
}

test "a placeholder with no argument panics" {
  assertPanicsWith("format1 {1}", "has no argument", { -> val _ = format1("{1}", 5) })
  assertPanicsWith("format2 {2}", "has no argument", { -> val _ = format2("{0}{2}", 1, 2) })
  assertPanicsWith("format3 {3}", "has no argument", { -> val _ = format3("{3}", 1, 2, 3) })
  assertPanicsWith("format4 {4}", "has no argument", { -> val _ = format4("{4}", 1, 2, 3, 4) })
  assertPanicsWith("long index", "has no argument", { -> val _ = format1("{99999999999999999999}", 5) })
}

test "a malformed placeholder or a lone brace panics" {
  assertPanicsWith("unclosed", "malformed placeholder", { -> val _ = format1("{0", 5) })
  assertPanicsWith("empty", "malformed placeholder", { -> val _ = format1("{}", 5) })
  assertPanicsWith("non-digit", "malformed placeholder", { -> val _ = format1("{x}", 5) })
  assertPanicsWith("format spec", "malformed placeholder", { -> val _ = format1("{0:X}", 5) })
  assertPanicsWith("alignment", "malformed placeholder", { -> val _ = format1("{0,5}", 5) })
  assertPanicsWith("trailing {", "malformed placeholder", { -> val _ = format1("a{", 5) })
  assertPanicsWith("lone }", "unmatched '}'", { -> val _ = format1("a}b", 5) })
}

test "UInt and ULong arguments at and above the sign bit format unsigned" {
  val u: UInt = 2147483648u32
  val ul: ULong = 9223372036854775808u64
  assertEqual(format1("{0}", u), "2147483648", "UInt sign bit local")
  assertEqual(format1("{0}", ul), "9223372036854775808", "ULong sign bit local")
  assertEqual(format1("{0}", 4294967295u32), "4294967295", "UInt max literal")
  assertEqual(format1("{0}", 18446744073709551615u64), "18446744073709551615", "ULong max literal")
  val c = Counts(small = 3000000000u32, big = 18446744073709551615u64)
  assertEqual(format2("{0} {1}", c.small, c.big), "3000000000 18446744073709551615", "record fields")
  assertEqual(format2("{1} {0}", bigUInt(), bigULong()), "18446744073709551615 4294967295", "call results")
  val us: slice[UInt] = [2147483647u32, 2147483648u32]
  assertEqual(format3("{0} {1} {2}", us[0], us[1], 1), "2147483647 2147483648 1", "slice elements")
  val bx = Box(value = 4294967295u32)
  assertEqual(
    format4("{0}|{1}|{2}|{3}", bx.value, u, ul, 0u32),
    "4294967295|2147483648|9223372036854775808|0",
    "generic field"
  )
  val t: Tally = Tally.from(4000000000u32)
  assertEqual(format1("{0}", t), "4000000000", "UInt range subtype")
}

test "a template need not be a literal" {
  val t = "n={0}, m={1}"
  assertEqual(format2(t, 1, 2), "n=1, m=2", "local template")
  assertEqual(format1("{0}" + "!", "hi"), "hi!", "computed template")
}

test "non-ASCII template text is copied unchanged" {
  assertEqual(format1("café {0} 😀", "ok"), "café ok 😀", "accented and supplementary")
  assertEqual(format1("{0}", "😀"), "😀", "supplementary argument")
}

test "the template and arguments are evaluated once, left to right" {
  val log: List[Int] = newList()
  val s = format3("{2}{1}{0}", logged(log, 1), logged(log, 2), logged(log, 3))
  assertEqual(s, "321", "result")
  assertEqualInt(log.count, 3, "each argument evaluated once")
  assertEqualInt(log[0], 1, "first")
  assertEqualInt(log[1], 2, "second")
  assertEqualInt(log[2], 3, "third")
}
