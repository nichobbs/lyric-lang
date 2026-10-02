# 68. Structured tasks: a first-class `Task[T]`, scope-bound `spawn`, and bounded waits

_Status: **Partly implemented.** §4's `spawn`-only-inside-`scope` rule (`V0034`) shipped in D165; the rest is a proposed, unimplemented sketch. Extends docs/01 §7.1,
§7.3 and §7.4 and decision D119. Open questions Q-TASK-001 to Q-TASK-008 are
listed in §9._

## 1. Why this exists

Two things surfaced while fixing a crash in a downstream application
(nichobbs/lyric-lang#8026, nichobbs/cloud-agents#1269):

1. **The spec and the checker disagree about what an `async` call is.**
   docs/01 §7.1 says an `async func` "returns a value of type `Task[T]`", and
   also says a direct call awaits in place. The type checker has no task type at
   all: a direct call, an `await` and a `spawn` handle are all typed as the
   callee's logical result `T`. The consequences were:
   - a generic called with a `spawn` handle specialised over `T`, not over the
     task (a `void` parameter on MSIL, `TypeLoadException` at startup);
   - a `Task`-typed parameter rejects a handle (`T0043`);
   - the mono pass needs a special case (`spawnHandleTEMono`) to say "this `T`
     is really a task".
2. **There is no way to wait on a task with a time limit, then wait again.**
   The application needs "wait up to 1.5 s, look at progress, wait again". The
   only tools are the closure-based `Std.Task.runWithin`, which restarts the work
   on every call, and a hand-written generic binding of `Task.Wait`, which is
   exactly what crashed.

The design below fixes both by giving the handle a real type and a small API,
and by making the lifetime of a handle lexical.

## 2. Principles

- **A direct call to an `async func` awaits in place** (unchanged, §7.1). Async
  code reads like sync code. `spawn` is the only way to get concurrency.
- **Concurrency is structured.** A spawned task cannot outlive the `scope` that
  started it, and its failure cannot be lost.
- **The handle is a Lyric type, not the platform's.** It maps to .NET `Task<T>`,
  a JVM subtask and a native task, but programs cannot name or depend on those.
- **No special-casing in mono or the backends.** Once the handle has a type, a
  generic over a handle is an ordinary generic over `Task[R]`.

## 3. The type

`Task[T]` is a built-in generic type, like `List[T]`. The bare name `Task` is an
alias for `Task[Unit]`.

| Expression | Type | Meaning |
|---|---|---|
| `f(x)` (direct call, `f` async, result `R`) | `R` | awaits in place (unchanged) |
| `await f(x)` | `R` | same; the keyword is optional (Q-TASK-001) |
| `spawn f(x)` | `Task[R]` | starts `f` now, returns its handle |
| `await t` (`t: Task[R]`) | `R` | waits for completion, yields the result |

`spawn` accepts a call to an `async func` (the call may be parenthesised).
Spawning anything else is a type error.

Today `Std.Task` declares `extern type Task = "System.Threading.Tasks.Task"` and
`delay(ms): Task`. That alias goes away: `delay` returns `Task[Unit]`. The BCL
type stays reachable only inside `_kernel/` (docs/14).

## 4. Scope-bound `spawn`

`spawn` is allowed only lexically inside a `scope { ... }` block (§7.4). This
widens V0014 (today: a discarded `spawn` statement outside a scope) to every
`spawn` outside a scope. The new code is `V0034`, so existing V0014 tests keep
their meaning.

A scope guarantees, on all targets:

- every task spawned in it has completed or been cancelled before the scope
  exits;
- if a task fails, its siblings are cancelled and the first failure propagates;
  later failures are attached to it (the `aggregated` field in §7.4);
- the scope's body is the only place a handle can be used.

### 4.1 Handles do not escape

A `Task[T]` value is valid only inside the scope that created it. The checker
rejects (`V0035`):

- a scope block whose result type mentions `Task[...]`;
- assigning a handle to a variable declared outside the scope;
- storing a handle in a record field, a `Map`, or a closure that is returned out
  of the scope.

A handle may be passed down: to a function parameter, into a `List[Task[T]]`
local to the scope, or captured by a closure that does not leave the scope. A
function cannot return a `Task[T]`. This keeps the rule local and checkable
without lifetime parameters. Q-TASK-004 asks whether to go further.

### 4.2 What this fixes on the JVM

The spec records that a `spawn` outside a scope is degenerate-synchronous on the
JVM: it runs to completion on the calling thread at the spawn site (§7.4, D119).
With `spawn` required to be in a scope, every `spawn` forks, and that special
case disappears from the spec.

## 5. The `Task[T]` API (module `Std.Task`)

```
pub func waitFor[T](t: in Task[T], timeoutMs: in Int): Bool
pub func isDone[T](t: in Task[T]): Bool
pub func cancel[T](t: in Task[T]): Unit
pub func awaitAll[T](ts: in List[Task[T]]): List[T]
pub func awaitAny[T](ts: in List[Task[T]]): T
```

- **`waitFor`** blocks up to `timeoutMs` and returns whether the task finished.
  It does not consume the task and can be called repeatedly. It never throws on
  timeout. If the task already failed, it returns `true` and the failure is
  raised by the later `await`. Requires `timeoutMs >= 0`. This replaces the
  hand-written `Task.Wait` binding.
- **`isDone`** is `waitFor(t, 0)`.
- **`cancel`** requests cooperative cancellation (§7.3). It is idempotent. The
  task still has to be awaited, or be left for the scope to join.
- **`awaitAll`** is the `Promise.all` case: it returns results in input order.
  On the first failure it cancels the rest and raises that failure. The empty
  list yields an empty list.
- **`awaitAny`** returns the first result and cancels the rest (Q-TASK-006).

The scope-local list pattern replaces a dynamic fan-out:

```
async func loadAll(ids: in List[UserId]): List[Profile] {
  scope {
    val tasks: List[Task[Profile]] = newList()
    for id in ids {
      tasks.add(spawn loadProfile(id))
    }
    return awaitAll(tasks)
  }
}
```

The fixed-arity case from §7.4 (`await a`, `await b`) stays valid and needs no
library call.

### 5.1 `runWithin` stays

`Std.Task.runWithin` keeps its role: run one closure off the calling thread and
give up after a limit. It is the sanctioned way to say "abandon this work if it
is slow", because a timed-out task keeps running with nobody joining it, which a
scope forbids. Its doc comment gains a pointer to `waitFor` for the resumable
case.

## 6. Cancellation and failure

- `cancel`, a failing sibling, and a panic that escapes the scope body all use
  the one cooperative token of §7.3. A task that never reaches a cancellation
  point is not interrupted. The scope still waits for it, so a stuck task blocks
  scope exit. Q-TASK-005 asks whether a scope needs a cancel-then-abandon
  deadline.
- A failure is propagated by whichever of `await`, `awaitAll` or scope exit
  observes it first. A failure no `await` observed surfaces at scope exit.

## 7. Compiler changes

1. **Checker.** Add `Task[T]` to the type universe. Type `spawn e` as
   `Task[R]` and `await t` as `R`. Add `V0034` (spawn outside a scope) and
   `V0035` (handle escapes). Keep `asyncCallSites` (it drives the in-place
   await lowering).
2. **Mono.** Delete `spawnHandleTEMono` and the `asyncCallSites` parameter added
   in #8026. A generic over a handle now specialises over `Task[R]` through
   normal inference. The mono tests added for that fix are rewritten against the
   new type, not removed.
3. **MSIL.** `Task[R]` lowers to `Task<R>` (`Task` for `Unit`).
   `waitFor` is `Task.Wait(int)`. `awaitAll` uses `Task.WhenAll` with a
   fail-fast continuation that cancels the linked source (D119 slice S6
   already does this for a scope's join).
4. **JVM.** `Task[R]` lowers to the subtask handle of the enclosing
   `StructuredTaskScope`. `waitFor` is a timed join on it. Because a scope
   already forks, `awaitAll` is a join over its subtasks.
5. **Native.** `Task[R]` is the runtime task of D-N-022. `waitFor` parks the
   caller with a deadline on the cooperative scheduler.
6. **Instance externs.** With `Task[T]` a real type, passing a `Unit` to a
   `Task`-typed extern receiver is `T0043`. The generic-receiver idiom that
   crashed is no longer expressible, so no new build diagnostic is needed.

## 8. Migration

- Apply in this order, each shippable alone: (1) type and API behind the
  existing rules; (2) `V0034` as a warning for one release, then an error;
  (3) `V0035`.
- `V0034` breaks bare `spawn` outside a scope. docs/63 set the precedent of a
  clean break instead of a deprecation window (D132), so the warning release is
  optional (Q-TASK-007).
- Stdlib and ecosystem call sites that bind a handle outside a scope move into a
  `scope`. The known external one is `src/docker_manager.l` in cloud-agents,
  which replaces its `taskWaitMs[T]` binding with `waitFor` and runs each poll
  loop inside a scope; on timeout it calls `cancel` and lets the scope exit
  instead of abandoning the task.
- `docs/01` §7.1 is rewritten so the sentence "returns a value of type
  `Task[T]`" is true only of `spawn`.

## 9. Open questions

- **Q-TASK-001: is `await` kept?** Today the keyword is optional and means
  nothing extra. Options: keep as is; add a `lyric lint` rule that flags a direct
  async call with no `await` at a suspend point; or make `await` mandatory and
  have a bare call return a task (reverses §7.1, and JVM and native). This
  sketch assumes "keep as is".
- **Q-TASK-002: name of the abandon operation.** `runWithin` covers one-shot
  bounded work. Is a `detach` needed for long-lived background work, with its
  failures reported to a handler? This sketch assumes no.
- **Q-TASK-003: `Task` as a bare name.** Alias for `Task[Unit]` as written, or
  require `Task[Unit]` everywhere.
- **Q-TASK-004: escape rule strength.** The local rules in §4.1 versus a
  lifetime-parameter scheme. This sketch takes the local rules.
- **Q-TASK-005: stuck tasks.** Should a scope have a cancel-then-abandon
  deadline, or always wait?
- **Q-TASK-006: `awaitAny`.** Needed, or leave racing to a later addition.
- **Q-TASK-007: deprecation window** for `V0034` (§8).
- **Q-TASK-008: generators.** An async generator is `IAsyncEnumerable[T]` and is
  not a `Task[T]`. This sketch leaves §7.2 unchanged.

## 10. What is not changed

- A direct call to an `async func` awaits in place, on every target.
- `scope { }` semantics beyond making `spawn` require it.
- The implicit cancellation token of §7.3.
- `Std.Task.runWithin` and `runActionWithin`.
