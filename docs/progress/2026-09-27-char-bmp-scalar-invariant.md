# 2026-09-27 — Every way of obtaining a `Char` keeps it a BMP scalar

D-progress-1006, #7505. Builds on D-progress-1003 (#7252).

- **`s[i]`** fails when the code unit at `i` is a UTF-16 surrogate half
  (`IndexOutOfRangeException` / `StringIndexOutOfBoundsException`, the
  out-of-range exception on each target). On native it panics when the byte
  offset does not start a BMP character.
- **`s.codeUnitAt(i): Int`** — new built-in `String` method on all three
  targets, the raw code unit.
- **`Std.String`**: `codeUnitAt`, `codePointAt` (lone halves decode to
  U+FFFD), `codePoints`, `charAtOrReplacement`; `charAt`/`first`/`last`
  return `None` where `s[i]` would fail and now compile on `--target native`.
- **`for c in s`** is **T0126** (it used to type-check and then throw at
  runtime).
- **`.toChar()`** on `Int`/`Long`/`Double` is checked (`OverflowException`,
  `ArithmeticException`, native panic); `Std.Char.tryFromInt` is the
  non-panicking form.
- **Lexer**: `'😀'` is L0022 (was L0024); a stray emoji is one L0030; emoji in
  string literals, comments and doc comments lex without `s[i]`.
- **Migration**: every string index in the compiler, stdlib (all three kernel
  trees) and ecosystem libraries was surveyed; text-facing sites moved to the
  code-unit / code-point views. See the decision entry for the list.
- **Tests**: `string_code_points_self_test.l` (dotnet, JVM, native),
  `string_bounds_self_test.l` and `conv_methods_self_test.l` (dotnet, JVM),
  new lexer/fmt/type-checker self-test cases, `lyric_rt_test.c` for native
  `s[i]`.
