# `spawn` is allowed only inside a `scope { }` (V0034, D165, docs/68 slice 1)

The mode checker rejects every `spawn` that is not lexically inside a
`scope { }` of the same function or lambda body (`V0034`). A discarded `spawn`
statement outside a scope keeps its `V0014`; each spawn gets one diagnostic.

Why first: the JVM gives a `spawn` handle a `Future` only inside a scope and
the raw result outside one, so the typed `Task[T]` handle of docs/68 needs
every spawn to be in a scope. `modechecker_self_test.l` has ten new cases
(bound, awaited, trailing, discarded, nested in `if`/loop/`match` inside a
scope, a lambda with and without its own scope, a test block, a sync
function).

Existing code moved into scopes: `async_extern_self_test.l`,
`async_sm_self_test.l`. The `async_spawn_self_test.l` case for a bare spawn
(the degenerate path) is removed, since the construct no longer compiles.
docs/01 §7.4, docs/09 §15.2, docs/18 and the book's async chapter are updated;
the book also said a call to an async function returns a task, which stopped
being true when #7838 made a direct call await in place.

Next slices: the built-in `Task[T]` type and the `Std.Task` API
(`waitFor`/`isDone`/`cancel`/`awaitAll`) on dotnet and jvm, then `V0035`.
