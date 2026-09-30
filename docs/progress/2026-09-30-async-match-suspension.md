# MSIL: `match` arms across a real `await` in an `async func` (#7816)

## The bug

On `--target dotnet` an `async func` is an `IAsyncStateMachine` whose
`MoveNext` is re-entered after every real suspension, and every IL local
reverts to its default on re-entry.  #7766 kept a `for` loop's state in
state-machine fields; a `match` arm's pattern bindings were still IL locals.
An `await` in the arm body that actually suspended lost them:

```lyric
async func f(o: in Option[Int]): Int {
  match o {
    case Some(v) -> { await Std.Task.delay(5); v * 2 }
    case None -> 0
  }
}
// f(Some(21)) returned 0; expected 42
```

A probe of every binding form that can hold IL-local state across a
suspension found, before the fix:

| Form | Result on `--target dotnet` |
|---|---|
| Union constructor pattern (`Some(v)`, user union cases) | lost binding (0) |
| Record pattern (`MatchPoint { x, y }`) | lost bindings (0) |
| Nested pattern (`Some((n, s))`) | lost bindings |
| `@` binding (`whole @ Some(v)`) re-matched after the await | `match not exhaustive` panic |
| Guarded arm with a suspending body | lost binding |
| Statement-position `match` | lost binding (empty string) |
| `match` in a `for` body | lost binding |
| `t += await f()` | `InvalidProgramException` |
| Guard holding the function's only `await` | ran, but blocked the thread: the function was not compiled as a suspending state machine |
| Tuple scrutinee (`match (a, b)`) | correct (the tuple is hoisted to a promoted `val`) |
| Destructuring `val (a, b) = p` then `await` | correct (#6249) |
| Call/constructor/method arguments, list and tuple literals, interpolation segments, `while` conditions with `await` | correct (`Lyric.AwaitHoist`, #5606) |
| `?` after an `await` (`(await f())?`), `xs[i] += await f()` | correct |
| `await` in a `catch`/`try` body | rejected at compile time (V0012) |

The language has no `if let`, `is`-pattern or `while let` forms, so `match`
is the only pattern-binding expression besides `for` and `val`.

## The fix

- **Arm bindings.**  An arm whose guard or body can suspend registers every
  name its pattern binds through `phaseBRegisterAndSyncLocal`, keyed by IL
  slot (`keepPatternBindsAcrossAwaitMsil`, shared with #7766's loops).  The
  key is now `__slot_<slot>` for both; two arms binding `v` at different
  types get distinct fields.  An or-pattern's alternatives are included.
- **Scrutinee.**  When any arm's guard can suspend, the scrutinee's hidden
  temporary is kept too: a later arm's pattern test reads it after an
  earlier guard resumed and failed.  An arm body never returns to the
  scrutinee, and a pattern's destructuring temporaries are consumed before
  the guard runs, so neither needs a field otherwise.
- **Guards.**  `exprContainsAwaitMsil` now walks arm guards, matching
  `collectAwaitTypesExprPB`, so an `await` in a guard makes the function a
  suspending state machine.  `countPromotedLocalsExpr` and
  `countSpillsExpr` walk guards too.
- **Field prediction.**  Pass 1 (`countPromotedLocalsExpr`) reserves one
  field per name each suspending arm's pattern binds plus the scrutinee's
  (`matchAwaitFieldsUpperBoundMsil`), from the same predicates the lowering
  applies (`matchArmCanSuspendMsil`, `matchGuardsCanSuspendMsil`); the state
  machine is padded up to the prediction (#6515).
- **Compound assignment.**  `t += await f()` loaded `t` onto the evaluation
  stack before the value suspended.  `Lyric.HoistEngine`'s
  `hzAssignTargetStacks` now treats a compound assignment to a bare name
  like a field or index target: the value is bound to a fresh local first,
  so the target is read after the value is evaluated.  The rewrite runs on
  every backend (and for `?`, whose instantiation shares the engine), so
  evaluation order stays identical across targets.

**JVM.**  `--target jvm` lowers `async func` synchronously, so every case
already passed there; the new test pins that parity.

## Tests

`lyric-compiler/lyric/async_match_suspend_self_test.l` (18 cases, dual
target, every case suspending through `Std.Task.delay`): union, user-union,
tuple, record, nested, `@` and or-patterns; a suspending guard whose
failure falls through to the next arm; a guard holding the only `await`; a
plain guard with a suspending body; statement- and value-position matches;
two awaits in one arm; one name bound at two types; a `match` inside a
`for` body; a destructuring `val`; `+=`/`*=` with an awaited value on
`Int` and `String`; and a record declared after every `async func`, which
reads back correctly only if each Pass-1 field prediction held.  It runs
in the compiler and JVM-generics batches and in
`scripts/ilverify-selfhosted.sh` phase 4.

`async_for_loop_suspend_self_test.l` gains two cases (19 total) for a panic
in a `for` body after a real resume, over a generator and over a list,
caught by the calling function; the generator's `finally` runs once
through the disposal fault handler.

## Found, not fixed here

A list literal mixing `Some(...)` and a bare `None`, iterated and matched,
reads garbage for the `Some` payload on `--target dotnet`, in an ordinary
synchronous function too (`for o in [Some(1), None, Some(3)] { match o {
case Some(v) -> { t = t + v } case None -> () } }` gives a large
nonsense value instead of 4; `--target jvm` gives 4).  It is independent
of suspension and needs its own issue.
