# D-progress-1006 — Every way of obtaining a `Char` keeps it a BMP scalar (#7505)

**Status:** shipped

Builds on D-progress-1003 (#7252, `Std.Char.fromInt` rejects surrogates).

## Context

The language reference defines `Char` as a BMP scalar value — one UTF-16
code unit in U+0000..U+FFFF outside the surrogate range U+D800..U+DFFF
(§1 character literals, §2.1). Issue #7505 listed the paths that broke that
definition after D-progress-1003 closed `fromInt`:

- `s[i]` returned "the code unit at index `i`", so indexing an emoji gave a
  surrogate-half `Char`;
- `n.toChar()` on `Int`/`Long`/`Double` narrowed any value, surrogates
  included;
- string iteration, which the issue assumed yielded code units.

The project owner chose option 1: keep the definition and make every path
honour it.

## Decisions

1. **`s[i]` keeps returning `Char` and fails on a surrogate half.** The
   failure is the same class as an out-of-range index on each target:
   `IndexOutOfRangeException` on .NET and `StringIndexOutOfBoundsException`
   on the JVM, with the message `string index: the code unit at this index
   is a UTF-16 surrogate, which is not a Char; use s.codeUnitAt(i) or
   Std.String.codePointAt(s, i)`. On native, where `i` is a byte offset
   (D-N-006), `lyric_string_char_at` already decoded UTF-8; it now also
   panics when the offset does not start the well-formed encoding of a BMP
   scalar (a continuation byte, a supplementary-plane character, a
   CESU-encoded surrogate). Returning `Option[Char]` from `s[i]` was
   rejected: every ASCII scanner in the tree would pay an unwrap for a case
   it never sees, and `Std.String.charAt` already is the `Option` form.

2. **`s.codeUnitAt(i): Int` is the raw accessor**, a new built-in `String`
   method on all three targets (UTF-16 unit on .NET/JVM via `get_Chars` /
   `charAt`; the UTF-8 byte on native via `lyric_string_byte_at`). It is the
   only way to observe a surrogate half. `s.length` already counts code units.

3. **`Std.String` gains the code-point API**, pure Lyric over a new
   per-target kernel pair (`hostCodeUnitAt`, `hostCodeUnitsAreUtf8`):
   - `codeUnitAt(s, i): Int` — the free-function form (see *Bootstrap* below);
   - `codePointAt(s, i): Int` — the scalar whose encoding starts at `i`; a
     valid pair decodes to its supplementary value, and a lone or trailing
     surrogate (or an ill-formed UTF-8 byte on native) is U+FFFD. The
     postcondition guarantees a scalar value, so
     `Std.Encoding.codepointToString` always accepts the result and
     decode/re-encode round-trips. Returning the lone surrogate (the JVM's
     `String.codePointAt` behaviour) was rejected because it reintroduces
     non-scalar values into "code point" results; throwing (.NET's
     `Char.ConvertToUtf32`) was rejected because text from the outside world
     routinely carries lone halves and a decoder should not abort on them —
     U+FFFD is the Unicode-sanctioned lossy decode (Rust `from_utf16_lossy`,
     .NET `Rune.DecodeFromUtf16`, WHATWG).
   - `codePoints(s): slice[Int]` — every scalar value, decoded the same way;
   - `charAtOrReplacement(s, i): Char` — the `Char` at `i`, or U+FFFD where
     no `Char` starts, for scanners that dispatch on ASCII/BMP syntax and copy
     the text between delimiters with `substring`;
   - `charAt`/`first`/`last` now return `None` where `s[i]` would fail
     instead of panicking (their postconditions go through a non-generic
     `noChar`, which also makes them compile on `--target native`).

4. **A `String` is not iterable.** `for c in s` never worked: it type-checked
   as the lenient `TyError` and threw at runtime on both managed targets
   (`InvalidCastException` / `IncompatibleClassChangeError`) and was a
   compile-time panic on native. It is now **T0126** with a message naming
   `for cp in Std.String.codePoints(s)` and `s.codeUnitAt(i)`. Making `for`
   yield code points as `Int` was rejected: it would silently give a loop over
   a `String` a different element type from `s[i]`. Yielding `Char` and
   failing on the first astral character was rejected as the least robust
   option. The explicit views leave no ambiguity.

5. **`.toChar()` is a checked conversion.** On an `Int`, `Long` or `Double`
   receiver (a `Double` truncated toward zero first) it fails unless the value
   is in 0..65535 and outside 55296..57343; NaN fails. A `Byte` or `Char`
   receiver cannot fail and is unchanged. Failures raise `OverflowException`
   (.NET — the checked-narrowing exception; `ArgumentOutOfRangeException`'s
   single-string constructor would treat the message as a parameter name) and
   `ArithmeticException` (JVM — as `Math.toIntExact`), and `lyric_panic_msg` on
   native, all with `toChar: value out of range [0, 65535] or in the UTF-16
   surrogate range [55296, 57343]`. `Std.Char.tryFromInt` (D-progress-1003) is
   the non-panicking form. The two failure texts live in `Lyric.Lexer`
   (`stringIndexSurrogateMessage`, `toCharRangeMessage`), which all three
   backends already import.

6. **Char literals and `\u{…}` escapes.** The lexer already rejected
   surrogate escapes (L0023) and non-BMP escapes in char literals (L0022). A
   supplementary-plane character typed directly into a char literal (`'😀'`)
   used to surface as an "unterminated character literal" (L0024) because the
   lexer consumed one surrogate half; it is now L0022 with the whole pair
   consumed. A stray one outside any literal is one L0030 naming the whole
   character, not two halves.

## Backend shape

- **MSIL:** inline IL. `s[i]` follows `get_Chars` with
  `dup; ldc 0xD800; sub; ldc 0x800; clt.un; brfalse ok; …throw`. `.toChar()`
  range-checks with `cgt.un` (an `Int`), in 64 bits (a `Long`) or with ordered
  double compares (a `Double`, so NaN fails), then surrogate-checks, then
  `conv.u2`. Exception constructors are interned once per assembly.
- **JVM:** static helpers `__lyricCharAt(String, int)`, `__lyricToChar(long)`,
  `__lyricToCharD(double)` emitted into the package class only when called —
  the call site stays branch-free on any operand stack, the reason
  `__lyricCount` is a helper too. The lazy-emission flag list
  (`usesLyricCount: List[Bool]`) became `usedRuntimeHelpers: List[String]`.
- **Native:** `lyric_string_char_at` panics as described; `.toChar()` is an
  inline `icmp`/`fcmp` check branching to `lyric_panic_msg`.

## Bootstrap

`s.codeUnitAt` is unknown to the released seed compiler, which compiles the
compiler and the .NET stdlib in stage 1 (MSIL rejects an unknown `String`
method, #7099). Code the seed compiles therefore calls the
`Std.String.codeUnitAt` free function, whose .NET kernel reads the unit through
an `@externTarget("System.String.get_Chars")` binding and widens it to `Int`
before it leaves the kernel. The JVM and native kernels, which only the new
compiler builds, use `s.codeUnitAt(i)` directly. The free function is a
permanent part of the API — `Std.String` pairs most methods with a free form —
not a stopgap.

## Migration

Every `s[i]` in the repository was located with a temporary type-checker
trace (an env-gated warning on each `String` index and each `.toChar()`),
over the stdlib (dotnet and `--features jvm`), the whole compiler closure and
every ecosystem manifest. Code that can see arbitrary text moved to
`codeUnitAt` (unit arithmetic, hashing, encoders), `charAtOrReplacement`
(ASCII dispatch) plus `substring` for copying (so emoji survive), or
`codePoints` (per-character work such as percent-encoding). Notable fixes the
survey turned up: the MSIL `#US` heap writer and the JVM modified-UTF-8 writer
(string literals with emoji), the monomorphizer's string-literal key, the
formatter's `escapeStr`, the lexer's doc-comment and interpolation scan, the
test/bench synthesizers' name escaping, the TOML manifest parser, the doc
generator, the generator host, the LSP, `lyric-search`'s `pathEscape` (now
UTF-8-encodes whole code points instead of two replacement characters) and
`lyric-ws`'s `fitCloseReason` (cuts on code-point boundaries). The lexer's
`\u{…}` string escapes build supplementary characters with
`Std.Encoding.codepointToString` instead of two surrogate `Char`s (and its
`longToInt` stopped counting up one at a time). Sites that only ever see
ASCII — numeric literal bodies, identifiers, generated names, JVM
descriptors of generated classes — were left alone.
