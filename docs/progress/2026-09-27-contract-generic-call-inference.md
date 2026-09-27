# Generic calls on `result` in contracts infer their type arguments (#7466)

`ensures: isNone(result)` on a function returning `Option[Char]` failed with
M0004, so the stdlib had to write `isNone[Char](result)`. The contract
elaborator runs before `Lyric.Mono` and binds `result` to a synthetic
`__lyric_result_<n>` local. That binding had no type annotation, so Mono
could only type it from the returned expression. For an `if` over
`Some(...)`/`None`, or a bare `return None`, that expression gives Mono
nothing to work with, and `T` stayed unpinned. The type checker had typed
`result` as the declared return type all along.

The elaborator now annotates every `__lyric_result_<n>` binding with the
function's declared return type (`RenameCounter.resultTy`, set in
`elaborateFunctionBody`). This covers trailing results and early `return`s
in functions, protected-type entries, and the weaver's aspect-contract
wrappers. A range-refined return (`Int range 0 .. 10`) is annotated with its
underlying type, because `returnRangeChecks` already checks the refinement. A
return type that mentions `Self` is still left to inference. `requires:`
clauses, `old(...)` snapshots and loop invariants already inferred their
type arguments from typed parameters and locals. They are now covered by
tests too.

`lyric prove` does not run the monomorphizer, so it was never affected.

The explicit `[Char]`/`[Int]` type arguments in `Std.String` and `Std.Char`
have to stay until a seed release contains this fix. The stage-0 seed
compiler builds the stdlib bundle and still reports M0004 without them. The
comments there now give that reason.

Verified by:

- `mono_self_test.l`: five cases, elaborate-then-mono. They cover
  `isSome`/`isNone` on `result`, an early-return `result` with a two-argument
  generic, `requires:` together with `old(...)`, a protected entry, and a
  same-file generic (M0002).
- `contract_elaborator_self_test.l`: three cases that check the annotation on
  trailing, early-return and range-refined result bindings.
- `contract_generic_call_self_test.l`: a new runtime test on `--target
  dotnet` (`compiler-self-tests-batch.sh`) and `--target jvm`
  (`jvm-generics-self-tests-batch.sh`). For each contract, a satisfying call
  returns normally and a violating call panics.
