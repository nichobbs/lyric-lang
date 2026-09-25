# D-progress-956 — Linear-time string building and from-index search (#7257, #7258)

**Status:** shipped

## Problem

`a + b` on `String` copies both operands on every backend (MSIL
`String.Concat`, a fresh `StringBuilder` per `+` on the JVM,
`lyric_string_concat` on native), and no builder was reachable from Lyric
code. Every `acc = acc + piece` loop was therefore quadratic, including
`Std.String.join`/`joinList` themselves, so "collect the parts, then join"
was not a way out. Only the one-argument `indexOf` existed, so a forward
scan had to re-slice the remainder after each match (the `split` bug found
in #7220). The stdlib audit (epic #7256) found this shape in more than a
dozen modules.

## Decision

- **`Std.StringHost` kernel on all three targets.** .NET binds
  `System.Text.StringBuilder` and the ordinal
  `String.IndexOf(string, int, StringComparison)` overload (the ordinal
  enum value comes from the static-field `@externTarget` idiom). The JVM
  binds `java.lang.StringBuilder` and `String.indexOf(String, int)`, which
  is already ordinal. Native has no host builder: the builder is a record
  holding a `List[String]`, and `toString()` calls the new
  `lyric_string_concat_list`, which sums the lengths and copies once.
  `lyric_string_index_of_from` adds the offset form, and the shared native
  search now skips to candidate first bytes with `memchr`.
- **Public API in `Std.String`.** `StringBuilder` is an opaque type with
  `new`/`append`/`appendChar`/`toString`, following the existing
  `Type.method` convention (`Url.toString`). `indexOfFrom` returns
  `Option[Int]` and `indexOfFromRaw` the `-1` sentinel, matching the
  `indexOf`/`indexOfRaw` pair. Both require `0 <= from <= s.length` rather
  than clamping, because .NET throws and the JVM clamps; a contract makes
  every target agree. `join` and `joinList` build through the builder.
- **Native codegen fixes found on the way.** `.toString()` on a non-scalar
  receiver was always treated as the built-in scalar conversion, so a
  user-defined `T.toString` method could not be called on native; it now
  falls through to UFCS resolution. The native reachability walk keyed
  `sb.append(x)` on a local receiver as the static call `sb.append/1`,
  which names nothing, so the method was never bundled; a bare lower-case
  single-segment receiver now also contributes the member-name key.

A builder over `List[String]` plus a host `String.Join` was considered for
the managed targets and rejected: on MSIL `List[String]` is `List<object>`,
so passing it to a `string[]`/`IEnumerable<string>` overload is not
type-correct.

## Verification

`string_builder_self_test.l` (10 cases) passes on `--target dotnet`, `jvm`
and `native`, and runs in CI on all three. New `lyric-rt` C tests cover
`lyric_string_index_of_from` and `lyric_string_concat_list`, including under
AddressSanitizer. `lyric-stdlib/tests/string_tests.l` passes on dotnet and
JVM.
