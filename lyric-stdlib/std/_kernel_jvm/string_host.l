//! std/_kernel_jvm/string_host.l — JVM host boundary for linear-time string
//! building and ordinal from-index search.
//!
//! Mirrors `_kernel/string_host.l`. `Std.String.StringBuilder` is backed by
//! `java.lang.StringBuilder` (amortised O(1) append) and
//! `Std.String.indexOfFrom` by `String.indexOf(String, int)`, which is
//! already ordinal on the JVM (#7257, #7258).
//!
//! Internal: only Std.String should import this.
@axiom("java.lang.StringBuilder and String.indexOf(String, int) conform to their documented JVM contracts")
package Std.StringHost

extern type HostStringBuilder = "java.lang.StringBuilder"

pub func hostNewBuilder(): HostStringBuilder {
  HostStringBuilder.new()
}

// Tail-position form: a discarded auto-FFI instance call on a parameter
// receiver emits no invoke on this backend (#5379).
pub func hostAppend(sb: in HostStringBuilder, s: in String): Unit {
  sb.append(s)
}

pub func hostAppendChar(sb: in HostStringBuilder, c: in Char): Unit {
  sb.append(c)
}

pub func hostBuilderToString(sb: in HostStringBuilder): String {
  sb.toString()
}

// Ordinal search for `value` starting at UTF-16 index `from`; -1 when
// absent. The caller guarantees 0 <= from <= s.length.
pub func hostIndexOfFrom(s: in String, value: in String, from: in Int): Int {
  s.indexOf(value, from)
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
  if same { 1 } else { 0 }
}
