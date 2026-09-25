//! std/_kernel_native/string_host.l — native-target host boundary for
//! linear-time string building and ordinal from-index search.
//!
//! The `--target native` twin of `_kernel/string_host.l`, selected by the
//! native source loader by basename. There is no host `StringBuilder`, so
//! the builder collects its parts in a `List[String]` (amortised O(1) push)
//! and `lyric_string_concat_list` materialises the result with one
//! allocation sized from the summed lengths (#7257). `indexOfFrom` offsets
//! are byte offsets, matching this target's byte-indexed
//! `.length`/`.substring` model (D-N-006, #7258).
//!
//! Internal: only Std.String should import this.
@axiom("lyric_string_concat_list and lyric_string_index_of_from conform to their lyric_rt.h contracts")
package Std.StringHost

import Std.Collections

extern func rtConcatList(parts: List[String]): String = "lyric_string_concat_list"

extern func rtIndexOfFrom(s: String, value: String, from: Long): Long = "lyric_string_index_of_from"

extern func rtAsciiCaseCompare(a: String, b: String): Int = "lyric_string_ascii_case_compare"

// `String + Char` and `Char.toString()` have no native lowering (#6237),
// so a Char is appended through its code point.
extern func rtStrFromChar(cp: Int): String = "lyric_string_from_char"

pub record HostStringBuilder {
  parts: List[String]
}

pub func hostNewBuilder(): HostStringBuilder {
  HostStringBuilder(parts = newList())
}

pub func hostAppend(sb: in HostStringBuilder, s: in String): Unit {
  sb.parts.add(s)
}

pub func hostAppendChar(sb: in HostStringBuilder, c: in Char): Unit {
  sb.parts.add(rtStrFromChar(c.toInt()))
}

pub func hostBuilderToString(sb: in HostStringBuilder): String {
  rtConcatList(sb.parts)
}

// Ordinal search for `value` starting at byte offset `from`; -1 when
// absent. The caller guarantees 0 <= from <= s.length.
pub func hostIndexOfFrom(s: in String, value: in String, from: in Int): Int {
  rtIndexOfFrom(s, value, from.toLong()).toInt()
}

// ASCII case-insensitive comparison without allocating (#7269): 1 equal
// after folding A-Z, 0 both pure ASCII and different, -1 either contains a
// non-ASCII byte (the caller then compares full lowercase forms).
pub func hostAsciiCaseCompare(a: in String, b: in String): Int {
  rtAsciiCaseCompare(a, b)
}
