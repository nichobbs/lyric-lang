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
