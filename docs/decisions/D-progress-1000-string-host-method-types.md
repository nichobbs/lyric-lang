# D-progress-1000 — Real `TyFunction` types for the `String` host-method surface

**Status:** shipped

Fixes #7335.

## Problem

`stringIndexOfMember` (#6496) already gave `.indexOf`/`.lastIndexOf` on a
`String` receiver a real `TyFunction` type, so a call through it ran the
`ECall` arm's ordinary argument-count/argument-type validation. Every other
documented `String` host method — `.substring`, `.trim`/`.trimStart`/
`.trimEnd`, `.replace`, `.contains`/`.startsWith`/`.endsWith`, `.toLower`/
`.toUpper`, `.isNormalized`/`.normalize`, `.split` — fell through
`builtinMember`'s `TyPrim(PtString)` arm (which only ever recognised
`.length`/`.isEmpty`) all the way to `TyError`.

`TyError` is the checker's universal unifier: it satisfies any expected
type and passes any argument-type check silently. So a call like
`s.substring(0, 2)` type-checked with **zero** argument validation, and its
result — instead of being a known `String` — unified with whatever the
enclosing expression expected next. The issue's repro chains this into a
second method call: `s.substring(0, 2).indexOf(":")` with no
`import Std.String` in scope types `.indexOf` as `(String) -> Int`
(`stringIndexOfMember`'s own, correct, import-sensitive binding), but the
call this shadowed was hidden because the *receiver* type flowing into it
had already lost all information at the `.substring` step. Downstream,
`match t.indexOf(":") { case Some(i) -> ... case None -> ... }` matches an
`Int` scrutinee against `Some`/`None` patterns — normally rejected by
`caseParentMatchesScrutinee`'s `T0129` ("pattern is a case of a different
type") — and it silently compiled clean before this fix only because the
member typing masked the type information the checker needed at each step,
not because `T0129` itself was unsound.

## Decision

Add `stringHostMethodType(name): Option[Type]`
(`lyric-compiler/lyric/type_checker/typechecker_exprs.l`, next to
`stringIndexOfMember`) giving a real `TyFunction` for every documented
`String` host method (docs/01 §12.1) that both backends' hardcoded
`String`-method dispatch cascades implement
(`lyric-compiler/msil/codegen.l`, `lyric-compiler/jvm/codegen/04_calls.l`):

| Method | Type |
|---|---|
| `s.substring(start)` / `s.substring(start, count)` | `(Int, Int) -> String`, second param optional |
| `s.trim()` / `.trimStart()` / `.trimEnd()` | `() -> String` |
| `s.toLower()` / `.toUpper()` | `() -> String` |
| `s.normalize()` | `() -> String` |
| `s.isNormalized()` | `() -> Bool` |
| `s.replace(old, new)` | `(String, String) -> String` |
| `s.contains(sub)` / `.startsWith(prefix)` / `.endsWith(suffix)` | `(String) -> Bool` |
| `s.split(sep)` | `(String) -> slice[String]` |

`inferMemberBase`'s `TyPrim(PtString)` arm consults `stringHostMethodType`
right after `stringIndexOfMember` (which stays separate — its return type
depends on the file's `Std.String` import, which `builtinMember` and this
new function do not need to see). `.length`/`.isEmpty` are unaffected — they
stay bare field-style types in `builtinMember`, since neither is called
with parentheses.

`s.substring(start)`'s one-argument form needed the second (`count`) param
to be optional without splitting `.substring` into two differently-shaped
`TyFunction`s (a member callee's type is computed once, with no argument
count in hand — see `inferMemberBase`'s signature). `builtinOptionalTrailingArgs`
(previously hardcoded to recognise only the free function `assert`'s
optional message argument) grew an `EMember(_, "substring")` arm returning
`1`, matching the existing precedent exactly.

**Deliberately not a general "unknown `String` method" diagnostic.**
D-progress-971 tried exactly that shape for #7099 and reverted it: MSIL's
`String`-method surface is closed (this table is genuinely everything), but
JVM's is open — a method name outside this table still resolves through
`Jvm.AutoFfi` against real `java.lang.String` metadata (e.g. `.getBytes()`).
A single allowlist-gated diagnostic in the shared, target-agnostic
`Lyric.TypeChecker` cannot be correct for both targets. `stringHostMethodType`
returns `None` for any name it does not recognise, exactly like before —
that call keeps falling through to `builtinMember`/`TyError`, so JVM's wider
real-method surface is untouched and no new false positive is introduced.

## Tests

`typechecker_self_test.l` (`lyric-compiler/lyric/typechecker_self_test.l`):
the issue's own repro (`T0129` now fires instead of compiling clean),
`.substring`'s 1-arg/2-arg forms and its wrong-argument-type case (`T0043`),
`.toLower`'s wrong-arity case (`T0042`), `.trim`/`.trimStart`/`.trimEnd`,
`.replace` (including a wrong-typed second argument), `.split`'s
`slice[String]` result (verified via a chained `.length`) and its
wrong-typed argument, `.startsWith`/`.endsWith`/`.contains` and a
wrong-typed argument, `.isNormalized`/`.normalize`, and a chain of three
String host methods used back to back.

Full ecosystem regression: `for d in lyric-*/; do ./bin/lyric test
--manifest $d/lyric.toml; done` across every ecosystem library, compared
against a baseline captured with the pre-change `lyric` binary — no new
failures (see the PR for the pass/fail counts on both sides; the four
libraries that already fail on the baseline — `lyric-db`, `lyric-grpc`
against unresolvable external NuGet/Maven metadata in this sandbox, plus
one pre-existing `lyric-mcp`/`lyric-session` flake each — are unrelated to
this change and fail identically before and after it).

## Docs

- docs/01-language-reference.md §12.1: a paragraph after the method table
  noting every row now type-checks with a real signature, and the scope
  boundary against D-progress-971's JVM-auto-FFI finding.
- book/chapters/appendix-b-quick-reference.md: one sentence on the same
  point, in the existing String method-syntax paragraph.
