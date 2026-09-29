# `if`/`match` branches checked against the position's expected type (#7752)

`lyric-compiler/lyric/compiler_bugs_3502_3505_3547_self_test.l` failed to
type-check on both targets:

```
error[T0067] 213:3: incompatible branch types: Result[EnglishGreeter, <error>] vs Result[FrenchGreeter, <error>]
```

```
func makeGreeterDirect(lang: in String, name: in String): Result[Greeter, String] {
  if lang == "en" { Ok(value = EnglishGreeter(name = name)) }
  else if lang == "fr" { Ok(value = FrenchGreeter(name = name)) }
  else { Err(error = "unknown language: " + lang) }
}
```

The type checker typed every `if`/`match` branch bottom-up and joined the
branch types (`unifyBranchTypes`) without consulting the type the position
expects, so two branches of different concrete types that each satisfy the
declared return type were rejected. The same held in every position with a
declared type (`return`, an annotated `val`/`var`, an assignment, a call
argument, a record field), for `Option[Greeter]` and for a plain `Greeter`.
Separately, a union-case construction never adopted its expected
instantiation: `Ok(value = English(…))` typed as `Result[English, <error>]`
(the unconstrained `E` degraded to the wildcard), so even a non-branching
`val r: Result[Greeter, String] = Ok(value = English(…))` or the same `Ok`
passed as an argument was rejected (T0060/T0043) — only returns accepted it,
through `typeAssignable`'s covariance.

Type checker (`typechecker_exprs.l`, `typechecker_stmts.l`):

- `branchesAgainstExpected`: a consumed `if`/`match` whose position has a
  closed expected type (no `TyVar`/`TyError`/`TySelf` — those are wildcards
  to `typeEquiv` and would accept anything) takes that type when every
  value-producing branch satisfies it (`argSatisfiesParam`; `Never` and
  already-diagnosed branches absorbed). Otherwise the existing bottom-up join
  runs unchanged, so genuinely incompatible branches still get T0067, and
  branches that agree on a type the position rejects still get the
  consumer's own T0060/T0065/T0070. The relation is deliberately not the
  generic-covariant `typeAssignable`: a `Result[English, E]` value is a
  different CLR instantiation from `Result[Greeter, E]`.
- `adoptUnionCaseExpected`: a union-case construction checked against an
  instantiation of its own union is typed at that instantiation when each
  type argument already agrees or is a non-generic interface the argument
  implements. That mirrors MSIL's `buildGenericCaseCtorTok` (context type
  arguments win unless the context argument is itself a generic
  instantiation), so the checker never accepts an instantiation codegen does
  not build; `Ok(value = Box(v = En(…)))` against `Result[Box[Greeter], E]` is
  still rejected.
- `inferExprExpected` now forwards its expectation into `if`/`match`/`{}`/
  `unsafe {}` (the #7696 `tailExpected` chain), which covers `return`,
  annotated bindings and assignment. Call arguments defer `if`/`match`/block
  arguments to the existing expectation-aware second pass (as lambdas are)
  and let union-case-constructor arguments adopt the selected parameter's
  instantiation; `expectedCallArgTypes` now also supplies a non-generic
  record constructor's field types.
- Union-case construction now reports T0101 for a named argument that is not
  one of the case's fields. The test file itself wrote `Err(err = …)` (the
  field is `error`): it type-checked, MSIL built the case positionally, and
  the JVM backend matched the name and silently stored `null`.

Codegen — branches of different concrete classes were unreachable before, and
both backends mishandled them:

- JVM (`01_types.l`, `02_exprs.l`, `03_match.l`): the `if`/`match` result local
  took the first branch's class and `checkcast` the others to it
  (`ClassCastException: French cannot be cast to English`).
  `joinBranchResultType` widens two distinct classes to `java/lang/Object`
  (a union case with its parent or a sibling case gives the parent) and
  `retypeResultStores` re-frames the earlier stores. `recordVarGenericArgs`'s
  annotation fallback is now pre-resolved like a parameter's, so
  `val o: Option[Greeter] = Some(value = g)` no longer binds the payload as
  erased `Object` (`no matching instance or inherited method for
  'java.lang.Object.greet()'`).
- MSIL (`codegen.l`): the join reported the first branch's class although the
  verifier merges two classes to `object`, leaving unverifiable IL
  (`StackUnexpected: found object, expected Greeter`). `joinBranchTypeMsil`
  reports `MObject` for distinct classes (the parent union for union cases),
  and `downcastObjectToLyricClassMsil` casts an `object` value to a
  Lyric-declared class at every consumer: return, call argument, annotated
  binding, assignment (local, by-ref, field, `self` field, `result`), and
  record-constructor field.

Verification: `typechecker_self_test.l` gains eight cases (tail/`return`/
binding/assignment/argument/field positions for `Res[Greeter, String]`,
`Opt[Greeter]` and a plain interface; union-case adoption; negatives for a
non-implementing branch, a generic `T` expectation, an unannotated binding, a
`Res[En, String]` value, a nested generic argument, and T0101).
`compiler_bugs_3502_3505_3547_self_test.l` now passes on both targets, with
new cases asserting the dispatched greeting and `Err` payload in every
position, and is wired into `scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh` and the Makefile's
`TEST_EMITTER_FILES` (its "currently broken" note is removed). Probe programs
covering every position ran with identical output on `--target dotnet` and
`--target jvm`, and their DLLs pass `ilverify`.
