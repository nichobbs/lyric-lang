# D328 - A bare union case must be visible to the file; a restored dependency's imports keep their form (docs/70 phase 2c, #8722)

**Status:** shipped. Step 9 of docs/70 §13 phase 2c, after D322.

## Context

`nameIsSharedUnionCase` decides whether a bare name is a union case two
packages declare, so the expected type may pick the one. It counted every
same-named case in the symbol table (`symTableTryFindAllNamed`), so a bare
`TimedOut(...)` compiled in a file that imported `Std.Regex` only under an
alias (`regex_tests.l`), which docs/70 §4.3 says makes no name of the package
bare (#8722).

## Decision

1. **The candidates are the names the file can reach.** `nameIsSharedUnionCase`
   asks `symTableTryFindAllVisible`. A case reached only through an aliased
   import is no longer a candidate, so the bare spelling is `T0020`; the
   qualified spelling (`Re.TimedOut(...)`) or a selective import of the union
   (`import Std.Regex.{RegexError}`, which brings its cases) is the migration.
   `regex_tests.l` imports `RegexError`.
2. **Amends D322 item 2.** A restored dependency's imports were read as whole
   imports when only names were known. That is not a superset for ambiguity: a
   package the dependency imports selectively (`import Ui.Core.{View}`) became a
   whole import, and `Ui.Core`'s `FieldError` case collided with `Forms`'s
   `FieldError` (`T0123`, reported as `T0211` for `Ui.Forms`). The contract
   already records `wholeImports` and `selectedImports`
   (`<package>::<name>`), so `ImportedPackage.selectedImports` carries the
   latter (the MSIL and JVM restored paths fill it from the synthesised source
   and the contract) and `importDeclsFromNames` builds a whole import for each
   whole package, a selective import for each package with listed names, and an
   aliased import for any other: an aliased import makes no name bare.

## Census (docs/70 §12.2)

`lyric check` over every `lyric.toml` and every `lyric-stdlib/tests/*.l`
before and after the rule: the error lines are the same apart from line
numbers in packages that already fail for unrelated reasons. The one site that
relied on the old behaviour was `lyric-stdlib/tests/regex_tests.l`.

## Verification

`reject-corpus`: `bare_union_case_alias_only_import` (dotnet and JVM).
`typechecker_self_test`: a name-only dependency reads selective imports as
selective, and a whole import as whole.
