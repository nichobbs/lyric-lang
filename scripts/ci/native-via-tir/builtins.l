//! builtins.l - the String methods that are one runtime call, the numeric conversions between Int,
//! Long, Byte and Double, and `panic`, lowered from TIR (docs/70 phase 4a, D520).
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package BuiltinsViaTir

import Std.Core
import Std.Console as Console

func clean(s: in String): String {
  s.trim().toUpper()
}

func piece(s: in String): String {
  s.substring(2, 3) + "|" + s.substring(5)
}

func swap(s: in String): String {
  s.replace("a", "o")
}

func firstUnit(s: in String): Int {
  s.codeUnitAt(0)
}

func probes(s: in String): Bool {
  s.startsWith("he") and s.endsWith("lo") and s.contains("ell")
}

func widen(n: in Int): Long {
  n.toLong() * 1000000i64
}

func narrow(n: in Long): Int {
  n.toInt()
}

func approx(n: in Int): Double {
  n.toDouble() / 4.0
}

func fail(why: in String): Int {
  panic("bad: " + why)
}

func main(): Unit {
  println(clean("  hello  "))
  println(piece("abcdefgh"))
  println(swap("banana"))
  println(toString(firstUnit("A")))
  println(toString(probes("hello")))
  println(toString(widen(5000)))
  println(toString(narrow(4294967297i64)))
  println(toString(approx(3)))
  println(toString(fail("last")))
}
