# D221 - `Char` is a Unicode scalar value, identical on every target

**Status:** accepted (#8225). Slice 1 shipped: the FFI boundary check (item 6). Slices 2 and 3 (items 1 to 5, the
literal, library and representation change) are specified here and not yet implemented; they are tracked in #8225.
Supersedes the "Char is a BMP scalar" rule of D-progress-1003 and D-progress-1006 once slice 3 lands.

## Context

`Char` was defined as a BMP scalar value (U+0000..U+FFFF, no surrogates): one UTF-16 code unit on .NET and the JVM,
a 32-bit code point on native. That is three different things. A supplementary-plane character such as an emoji had no
`Char` on any target, a `'\u{1F600}'` literal was **L0022**, and the representations disagreed on whether
`Char.MaxValue` was 65535 or 1114111. #8225 asked which semantics to adopt; the owner chose a Unicode scalar value.

## Decision

1. **`Char` is one Unicode scalar value**: U+0000..U+10FFFF excluding the surrogate range U+D800..U+DFFF. It is the
   same set on every target. A `Char` is never half of a UTF-16 pair.
2. **Literals** accept any scalar value: `'😀'` and `'\u{1F600}'` are valid. **L0022** (non-BMP in a character literal)
   is retired; **L0023** (a surrogate escape) stays.
3. **Representation**: a 32-bit scalar on every target. Native already is (`i32`). On .NET and the JVM a `Char` stops
   being the CLR `char`/JVM `char` (a 16-bit code unit) and is carried as an `int32`, so a supplementary value fits.
   `Char` stays a distinct Lyric type: it does not unify with `Int`, and `toString`, interpolation, `String + Char` and
   `Std.Console` keep printing the character, encoding it as a surrogate pair on .NET and the JVM and as UTF-8 on native.
4. **Strings stay code-unit indexed.** `s.length`, `s[i]` and `s.codeUnitAt(i)` count UTF-16 units (UTF-8 bytes on
   native) exactly as today. `s[i]` yields the `Char` at a unit that is itself a scalar value and fails on a surrogate
   half, as now; the supplementary character is reached by `Std.String.codePointAt`/`codePoints` (unchanged,
   `Int`-valued) and by a new `Std.String.scalarAt(s, i): Char` and `Std.String.scalars(s): slice[Char]`, which decode
   a whole pair. Iterating by `Char` therefore never splits an emoji. `Std.String.charAt(s, i)` is unchanged.
5. **Library semantics are scalar-based on every target.**
   - `Std.Char.isLetter`/`isDigit`/`isUpper`/`isLower`/`isPunctuation`/`isControl` classify the scalar value (a
     supplementary letter is a letter), and `toUpper`/`toLower` apply the Unicode simple case mapping to the scalar.
     `isWhiteSpace` and the `isAscii*`/`asciiTo*` families are unchanged.
   - `Std.Char.toInt(c)` is the code point; `fromInt(n)` requires `n` in `0..=0x10FFFF` outside `0xD800..=0xDFFF`;
     `tryFromInt` returns `None` for the same inputs; `.toChar()` on an `Int`/`Long`/`Double` fails outside that set.
   - Ordering and `==` compare scalar values. `Char` is a range-subtype-like scalar for the verifier, which models it as
     `0..1114111` minus the surrogate range once item 3 lands (until then the verifier keeps `0..65535`, #8214).
   - `Std.Encoding.codepointToString(cp)` is unchanged; `Char.toString()` is its `Char` form.
6. **FFI boundary.** A .NET `char` or JDK `char` is a UTF-16 code unit, not a scalar value. A `char` that an auto-FFI
   call, a static property or field read, or a constant yields is therefore checked: a surrogate half panics
   (`OverflowException` on .NET, `ArithmeticException` on the JVM) and never becomes a `Char`. After item 3, a `Char`
   above U+FFFF passed to a `char` parameter panics the same way instead of truncating; APIs that take a code point
   (`Character.toChars(int)`, `Rune`) take an `Int`. `@externTarget` kernel declarations are audited code and are not
   checked; `Std.String`'s `codeUnitAt` reads the raw unit through one.

## Staging

| Slice | Content | Status |
| --- | --- | --- |
| 1 | This decision; docs/01 and book text; the FFI boundary check (item 6) on .NET and the JVM, with tests | shipped |
| 2 | Front end: lexer and parser accept supplementary literals (L0022 retired), `Char` constant folding, `.toChar()` and `Std.Char.fromInt` ranges, verifier model; `Std.String.scalarAt`/`scalars` | planned, #8508 (literals), #8512 (verifier, native) |
| 3 | Representation: `int32` `Char` on the MSIL and JVM backends (locals, fields, signatures, boxing, arrays, `switch`/match, string concatenation and interpolation, `StringBuilder`, auto-FFI conversion), scalar-based `Std.CharHost` kernels on all three trees, native agreement and tests on all three targets | planned, #8509 (MSIL), #8510 (JVM), #8511 (library and kernels), #8512 (native) |

Slices 2 and 3 cannot land separately from the user's point of view: a literal above U+FFFF needs the 32-bit
representation to exist on every target, so they ship together or behind one feature gate. Nothing in slice 1 changes
the behaviour of a program that never crosses the FFI boundary with a surrogate.
