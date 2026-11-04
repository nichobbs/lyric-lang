# D342 - Typing the first non-callee silent TyError sites (docs/70 phase 3a, D338, #8613)

**Status:** accepted; first slice of the 1,161 non-callee sites.

## Context

D338 counted 11,654 expressions the checker types `TyError` with no diagnostic,
1,161 of them not callee positions. The census instrumentation is merged this
time (`censusLogSilentTyError` in `typechecker_exprs.l`, off unless
`LYRIC_TYERR_CENSUS=1`; helper names are prefixed `census` and were checked
against every existing `func` name, since the first attempt shadowed
`Lyric.Parser.exprKindTag`, #8765). Re-running it over the compiler and stdlib
closure (`LYRIC_TYERR_CENSUS=1 ./scripts/bootstrap.sh --stage 2`) gave 11,661
distinct sites, matching D338.

## Decision

Three shapes get a real rule instead of a silent `TyError`:

1. **A qualified call of a codegen builtin** (`Std.Console.println(x)`,
   `Std.Console.print`) has the builtin's polymorphic signature, as the bare
   spelling does (D334). The imported stdlib `println` is deliberately never
   registered (it would tighten the builtin's parameter to `String`), so the
   qualified callee had no type. `qualifiedBuiltinCalleeType` applies the
   builtin signature only when a function of that name is declared by a
   package the qualifier names. 212 sites.
2. **Universal methods with no declared signature**: `x.toString()` is a
   `String`, `x.equals(y)` a `Bool`, `x.hash()` an `Int` (the types the
   `Equals`/`Hash` derives synthesise after the checker runs). Any other name
   or arity has no rule and stays untyped. 380 `toString` sites.
3. **`.count` on a stdlib `Map` or `Set`** is an `Int`, as on `List`. About 160
   sites; the compiler and stdlib already used it (`collections.l`).

## Census delta

| | before | after |
|---|---|---|
| distinct silent sites | 11,661 | 10,856 |
| non-callee (`ECall`, `EMember`, operators, `if`/`match`/`index`) | 1,163 | 386 |

Remaining non-callee: 272 call results (`default` 31, extern `.new` 28, host
methods such as `.clear`, `.Dispose`, `.add`, `Path.Combine`), 102 member
reads (extern properties, `.length` on a non-`String` receiver, `.count` on
two further receivers) and 12 other (5 operators, 3 `if`, 3 `index`, 1
`match`). They are the next slices; the I0001 gate stays off until they reach
zero.
