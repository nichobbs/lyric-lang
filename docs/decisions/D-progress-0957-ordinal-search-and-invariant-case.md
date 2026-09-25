# D-progress-957 — Ordinal string search on MSIL and locale-neutral case conversion (#7260, #7261)

**Status:** shipped

## Problem

- MSIL lowered `s.indexOf`, `s.lastIndexOf`, `s.startsWith` and `s.endsWith`
  to the single-argument `System.String` overloads, which compare with the
  current culture. Emitted programs run with ICU on Linux (their
  `runtimeconfig.json` does not request invariant globalization), so an
  ignorable code point such as U+00AD matched as an empty string
  (`"abc".IndexOf("­") == 0`) while the JVM and native targets, and
  .NET's own ordinal `Contains`, returned no match. Linguistic search is
  also much slower than ordinal. Everything built on these (`Std.String`,
  HTTP parsing, path handling) inherited the divergence.
- The JVM lowered `s.toLower()`/`s.toUpper()` to the no-argument
  `toLowerCase()`/`toUpperCase()`, and the .NET `Std.CharHost` bound
  `Char.ToUpper`/`ToLower`; both use the default locale, so under tr-TR
  'I' became dotless 'ı'. MSIL `String` casing and JVM `Char` casing were
  already invariant, so each target was wrong in a different place (#5557).

## Decision

- MSIL binds `IndexOf`/`LastIndexOf`/`StartsWith`/`EndsWith(string,
  StringComparison)` against a new `System.StringComparison` TypeRef and
  pushes `Ordinal` (4) at every call site.
- JVM passes `Locale.ROOT` (`getstatic java/util/Locale.ROOT`) to
  `toLowerCase`/`toUpperCase`.
- The .NET char kernel binds `Char.ToUpperInvariant`/`ToLowerInvariant`.

Forcing `System.Globalization.Invariant` in generated runtimeconfigs was
considered and rejected: it would change culture-dependent formatting that
user code may legitimately rely on, while the problem is confined to these
bindings.

## Verification

`string_ordinal_self_test.l` failed 1/4 on dotnet before the change and
passes 4/4 on dotnet, JVM and native after it. `string_case_locale_self_test.l`
failed on dotnet (`Char`) and JVM (`String`) under a Turkish default locale
before the change and passes on both after it; CI runs it under tr-TR.
