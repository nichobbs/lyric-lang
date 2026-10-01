//! std/_kernel/string_host.l — .NET host boundary for linear-time string
//! building and ordinal from-index search.
//!
//! `a + b` on String copies both operands, so accumulating a string in a
//! loop is O(n^2) on every target (#7256). This kernel backs
//! `Std.String.StringBuilder` with `System.Text.StringBuilder` (amortised
//! O(1) append) and `Std.String.indexOfFrom` with the ordinal
//! `String.IndexOf(string, int, StringComparison)` overload, so a forward
//! scan never has to re-slice the remainder (#7257, #7258).
//!
//! Internal: only Std.String should import this.
@axiom("System.Text.StringBuilder, String.IndexOf(string, int, StringComparison), String.CompareOrdinal(string, string) and String.get_Chars(int) conform to their documented .NET contracts")
@pure
package Std.StringHost

extern type HostStringBuilder = "System.Text.StringBuilder"

extern type StringComparison = "System.StringComparison"

@externTarget("System.StringComparison.Ordinal")
func ordinalComparison(): StringComparison = ()

@externTarget("System.String.CompareOrdinal")
func netCompareOrdinal(a: in String, b: in String): Int = ()

@externInstance
@externTarget("System.String.IndexOf")
func netIndexOfFrom(s: in String, value: in String, startIndex: in Int, comparison: in StringComparison): Int = ()

@externInstance
@externTarget("System.String.get_Chars")
func netCharAt(s: in String, index: in Int): Char = ()

// The UTF-16 code unit at `index`, surrogate halves included (D-progress-1006).
// The BCL hands the unit back as a `char`; it is widened to `Int` before it
// leaves this function because a surrogate half is not a valid Lyric `Char`
// (docs/01 §2.1). Out-of-range `index` throws IndexOutOfRangeException, as
// `s[i]` does.
pub func hostCodeUnitAt(s: in String, index: in Int): Int {
  netCharAt(s, index).toInt()
}

// Strings are UTF-16 on .NET, so a code unit is a UTF-16 unit.
pub func hostCodeUnitsAreUtf8(): Bool {
  false
}

pub func hostNewBuilder(): HostStringBuilder {
  HostStringBuilder.new()
}

pub func hostAppend(sb: in HostStringBuilder, s: in String): Unit {
  sb.Append(s)
}

pub func hostAppendChar(sb: in HostStringBuilder, c: in Char): Unit {
  sb.Append(c)
}

pub func hostBuilderToString(sb: in HostStringBuilder): String {
  sb.ToString()
}

// Ordinal search for `value` starting at UTF-16 index `from`; -1 when
// absent. The caller guarantees 0 <= from <= s.length.
pub func hostIndexOfFrom(s: in String, value: in String, from: in Int): Int {
  netIndexOfFrom(s, value, from, ordinalComparison())
}

// ASCII case-insensitive comparison without allocating (#7269): 1 when the
// strings are equal after folding A-Z to a-z, 0 when both are pure ASCII
// and differ, and -1 when either contains a non-ASCII character, in which
// case the caller decides with a full lowercase comparison (lowercasing a
// non-ASCII character can change the string's length, so no ASCII-only
// verdict is sound).
pub func hostAsciiCaseCompare(a: in String, b: in String): Int {
  var same = a.length == b.length
  var i = 0
  while i < a.length {
    val ca = hostCodeUnitAt(a, i)
    if ca > 127 {
      return 0 - 1
    }
    if same {
      val cb = hostCodeUnitAt(b, i)
      if cb > 127 {
        return 0 - 1
      }
      val la = if ca >= 65 and ca <= 90 { ca + 32 } else { ca }
      val lb = if cb >= 65 and cb <= 90 { cb + 32 } else { cb }
      if la != lb {
        same = false
      }
    }
    i = i + 1
  }
  var j = 0
  while j < b.length {
    if hostCodeUnitAt(b, j) > 127 {
      return 0 - 1
    }
    j = j + 1
  }
  if same {
    1
  } else {
    0
  }
}

// Ordinal (UTF-16 code unit) comparison in one pass: negative, zero or
// positive as `a` sorts before, equal to or after `b` (#7284).
pub func hostCompareOrdinal(a: in String, b: in String): Int {
  netCompareOrdinal(a, b)
}
