# D529: async lambdas and `out`/`inout` parameters of async functions on native

Status: recorded (phase 4a, part 5). No implementation: neither construct is a parity gap. Tracked in nichobbs/lyric-lang#9127.

## Finding

The coordinator asked for a design of two items the TIR lowering leaves on the AST path:
a second coroutine frame for async lambdas, and a by-reference slot that survives a suspension
for `out`/`inout` parameters of async functions. Checked against `docs/native-plan/06-async-design.md`
and the AST lowering (`lowerFunctionEnv`, `lowerLambda`, `unwrapTask`):

- **`out`/`inout` parameters of an async function are refused by the AST path.** `lowerFunctionEnv` panics for any async function that declares one, because a suspended coroutine cannot safely hold a pointer into the caller's frame across a suspend point (the caller regains control at the first suspend). The TIR lowering refuses them the same way (`an async function with an out or inout parameter`), so the function stays on the AST path and the build reports the AST path's error. There is no AST behaviour for TIR to match.
- **A lambda has no coroutine form on the AST path.** A lambda body is an ordinary function (`lowerLambda`); an `await` inside it waits through `unwrapTask` in a non-coroutine context. There is no frame to suspend and no `async` marker on a lambda expression. An `async` function type (`TFunc(..., isAsync = true)`) is not a lowerable closure type on either path (`funcType` and `closureNType` take plain parameter and result types).

So both items are new native-backend features, not parity gaps; the TIR path matches the AST path by refusing them.

## Design for when they are built (not scheduled)

- **By-reference parameters across a suspension.** Do not hand the coroutine a pointer into the caller's frame. The callee takes a heap cell (a counted box, as a by-value list element does, D520 slice 26) that the caller allocates, fills with the argument, passes by pointer-to-box, and copies back out of when the awaited call returns (copy-in, copy-out through the box). A spawned call (`spawn f(inout x)`) is refused: the box would outlive the argument's scope. The cell is retained by the coroutine parameter retention the prologue already does for references.
- **Async lambdas.** A lambda that awaits is its own coroutine: a closure whose function pointer is the coroutine's ramp (returning the task), with the captures in the closure object as now. Calling it is an awaited call of that ramp, as `lowerAsyncCall` does for a named async function; the nested prologue needs per-function names for the labels and values (`coro.id`, `coro.task`, ... are fixed today because one coroutine is assembled per function), which the TIR lowering must derive from the lambda's own symbol. The closure type carries `isAsync`, so `funcType` and `closureNType` register a distinct type per async signature.

Either item needs a language-reference sentence first (async lambdas and async by-reference parameters are not specified for native) and an owner decision to schedule it against 3c.
