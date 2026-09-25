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
@axiom("System.Text.StringBuilder, String.IndexOf(string, int, StringComparison) and String.CompareOrdinal(string, string) conform to their documented .NET contracts")
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
    val ca = a[i].toInt()
    if ca > 127 {
      return 0 - 1
    }
    if same {
      val cb = b[i].toInt()
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
    if b[j].toInt() > 127 {
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
