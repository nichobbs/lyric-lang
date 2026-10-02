# A `spawn` handle instantiates a generic over its task on `--target dotnet`

A generic function called with a `spawn` handle now specialises over the
callee's task object on MSIL instead of over the callee's logical result. The
case that surfaced it is a generic `@externInstance` binding of `Task.Wait`
(`func taskWaitMs[T](t: in T, timeoutMs: in Int): Bool`), but any generic took
the same wrong specialisation.

## What failed

The type checker types `spawn f()` as `f`'s logical result: `Unit` for a
`Unit`-returning `async func`, `Int` for an `Int`-returning one. `Lyric.Mono`
takes a generic call's type arguments from the checker when it cannot infer them
itself, so `taskWaitMs(handle, ms)` specialised as `taskWaitMs__Unit` /
`taskWaitMs__Int`. On MSIL the handle is the callee's `Task` / `Task<T>`, so:

- `T = Unit` lowered the receiver parameter to `void`, which is illegal in a
  parameter position: `TypeLoadException: The signature is incorrect.` as the
  class loaded, i.e. at startup, even when the function was never called.
- `T = Int` handed a `Task<int>` to an `int` parameter: an access violation.

## Fix

`Lyric.Mono.inferExprTE` now types `spawn <async call>` as `Task`, so the
specialisation is `taskWaitMs__Task`. `Task<T>` derives from `Task`, so the one
spelling is right for a value-returning callee too. The call is recognised from
the checker's `SymbolTable.asyncCallSites`, which `Lyric.Pipeline` passes to
mono only where it already passes it to `Lyric.Propagate` (`--target dotnet`);
on the JVM and native targets, where a handle is not a task object, the map is
empty and nothing changes.

## Not changed

A direct call to an `async func` awaits in place (docs/01 §7.1), so
`val t = f()` is the awaited result, not a task. Passing it to an instance
extern whose receiver is a `Task` is still wrong; take the handle with `spawn`.
A non-generic `Task`-typed parameter still rejects a handle with `T0043`, since
the checker gives the handle no task type.

Verified by four cases in `async_extern_self_test.l`: a `Unit`- and an
`Int`-returning callee, a timed-out wait followed by a completing one on the same
task, and a `spawn` expression passed directly as the argument.
