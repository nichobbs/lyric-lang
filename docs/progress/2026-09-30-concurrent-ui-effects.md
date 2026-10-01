# lyric-ui runs a session's effects concurrently (#7835)

`Ui.Host` used to run each step's effects one after another on the
connection's thread, so a slow effect blocked the others and the session's
input (docs/65 §15, F-15). Now (D148):

- Each effect runs on the instance's `Std.Task` scope, outside the instance
  lock.
- Its result is applied under the lock as a step of its own, one at a time
  in completion order, and that step's effects start the same way.
- `Instance.close` cancels the scope, and results arriving afterwards are
  dropped. `SessionRegistry` calls it on eviction and on expiry.
- A result for a detached session updates the model only.
- A failing effect is reported and produces no result.

`lyric-ui/tests/host_tests.l` adds three cases, and the busy-state test now
waits for the effect's result:
- two effects with different delays apply their results in completion
  order;
- input (`sync`) is handled while an effect is still running;
- a closed instance drops the result of an effect that was running.

The tests exposed an MSIL miscompile: a lambda passed straight to a record
constructor whose body is a bare `None` (or `Some`/`Ok`/`Err`) built the
case with `object` type arguments, so reading the field threw
`InvalidCastException`. Its result type now comes from the field's declared
function type. `lambda_field_ctor_arg_self_test.l` (5 cases, both targets,
in both batch scripts) covers it.

On the JVM, `Std.Task.scopeSpawn` queued its closure until `awaitAll`
instead of starting it, unlike dotnet, so no effect ran there. It now
starts each action at once on a virtual thread, and `awaitAll` joins them
(`task_tests.l`: `testScopeSpawnStartsBeforeAwaitAll`, both targets).

Filed along the way: #7868 (JVM J007 on `.isSome` of an annotated
`Option[M]` local in a generic function specialised into another package).
