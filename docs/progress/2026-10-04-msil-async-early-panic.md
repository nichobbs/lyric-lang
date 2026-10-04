# MSIL: an async panic before the first suspension is captured in the task (#8105)

On `--target dotnet`, an `async func` with no `await` in its body was lowered by the
Phase B.0 state machine, whose `MoveNext` had no try/catch. A panic in such a function
escaped `AsyncMethodBuilderCore.Start` and was thrown from the `spawn` or call
expression, while the JVM captured it in the task and raised it at `await` (docs/68 and
docs/01 §7.4 specify the latter).

All non-generator `async func`s now use the Phase B emitter, whose `MoveNext` records
the exception on the task builder with `SetException`. The B.0 emitter is deleted and
`countSmFieldsMsil` no longer special-cases bodies without `await`, so the Pass 1
field-count prediction matches Phase B's real field layout.

`async_spawn_self_test.l` gains a case (both targets) where a spawned task panics before
any suspension and a statement between `spawn` and `await` must still run.
