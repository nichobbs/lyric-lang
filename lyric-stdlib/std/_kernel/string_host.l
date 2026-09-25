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
@axiom("System.Text.StringBuilder and String.IndexOf(string, int, StringComparison) conform to their documented .NET contracts")
package Std.StringHost

extern type HostStringBuilder = "System.Text.StringBuilder"

extern type StringComparison = "System.StringComparison"

@externTarget("System.StringComparison.Ordinal")
func ordinalComparison(): StringComparison = ()

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
