# Async and Concurrency

Concurrency in Lyric is structured by default. There is no "fire and forget," no raw locks, and no way to accidentally share mutable state without going through a `protected type`. If you have written concurrent code in C# or Java, you know how much of the discipline is cultural: remember to `lock`, remember to propagate the `CancellationToken`, remember to await the tasks you spawn. Lyric makes the correct thing the only available thing.

This chapter covers Lyric's three concurrency primitives: async functions, structured scopes, and protected types. They are designed to compose. A `protected type` whose entries are `async` participates in the same cancellation and structured scope model as everything else. The pieces fit.

## §10.1 Async functions

An async function is declared with `async func` and returns a task:

```lyric
async func fetchUser(id: in UserId): User? {
  val response = await http.get("/users/${toString(id)}")
  return User.parseJson(response.body)
}
```

Under the hood, `async func fetchUser(...): User?` compiles to a .NET `Task<User?>`. You do not write this type yourself. The Lyric type of the function is `async func(...): User?`; the `Task` wrapping is a detail of the .NET lowering, not something you manage.

`await` is an expression, not a statement. This means you can use it anywhere an expression is expected:

```lyric
val user = await fetchUser(someId)

// Or inline, though the named binding is usually clearer:
return (await fetchUser(someId))?.name
```

Calling an async function does not automatically await it. The call returns a task, and you decide what to do with it: await it immediately, or pass it to a `scope` block to run concurrently with other tasks.

```lyric
// Awaited immediately — sequential
val a = await fetchA()
val b = await fetchB()

// Both tasks in flight — parallel (see §10.3)
scope {
  val taskA = spawn fetchA()
  val taskB = spawn fetchB()
  val a = await taskA
  val b = await taskB
}
```

## §10.2 Cancellation

Every async function receives an implicit cancellation token from the compiler. You do not declare it, you do not pass it, and you cannot forget it. Inside an async function, the token is accessible as `cancellation`:

```lyric
async func processItems(items: in slice[Item]): Unit {
  for item in items {
    cancellation.checkOrThrow()    // cooperative cancellation point
    await processOne(item)
  }
}
```

`cancellation.checkOrThrow()` checks whether the token has been cancelled and, if so, raises a `Bug` (specifically, `OperationCancelled`) that propagates up the call stack. This is cooperative cancellation: the function does not stop mid-instruction; it stops at points where you explicitly check, or at `await` expressions.

When `processItems` calls `processOne`, the same token is propagated automatically. The entire async call tree shares one cancellation signal. If you have five nested async calls, cancelling at the top cancels them all — you do not thread the token through each layer by hand.

::: sidebar
**Why implicit cancellation?** The most common mistake with explicit `CancellationToken` parameters in C# is forgetting to thread the token through one leg of a call graph. The result is a partially-cancellable async tree: some branches stop, others keep running, and resource cleanup behaves differently depending on which code path you are in. Making the token implicit eliminates the forgetting. Every async function participates in cancellation. The token is still there — `cancellation` gives you access — but propagation is the default, not the exception.
:::

## §10.3 Structured scopes

A `scope` block is Lyric's structured concurrency primitive. Tasks spawned inside a scope cannot outlive it:

```lyric
async func loadDashboard(userId: in UserId): Dashboard {
  scope {
    val profile       = spawn loadProfile(userId)
    val recent        = spawn loadRecentActivity(userId)
    val notifications = spawn loadNotifications(userId)

    return Dashboard(
      profile       = await profile,
      recent        = await recent,
      notifications = await notifications
    )
  }
}
```

`spawn` starts a task. The scope block does not exit until every spawned task has either completed or been cancelled. This gives you four guarantees that raw `Task.WhenAll` in C# does not:

1. **No task leaks.** A spawned task cannot escape the scope's lifetime. When the scope block's braces close, all work is done.
2. **Failure cancels siblings.** If `loadProfile` throws, `loadRecentActivity` and `loadNotifications` are cancelled before the exception propagates.
3. **First failure propagates.** The exception from the first failing task is the one you catch. You do not lose it in a `Task.WhenAll` aggregate.
4. **Subsequent failures are accessible.** If multiple tasks fail after the first, those exceptions are collected in the aggregate field of the propagated exception — nothing is silently swallowed.

Compare this to the typical C# pattern:

```csharp
// C# — raw Task.WhenAll
var profileTask       = LoadProfile(userId);
var recentTask        = LoadRecentActivity(userId);
var notificationsTask = LoadNotifications(userId);

await Task.WhenAll(profileTask, recentTask, notificationsTask);
// If profileTask fails, recentTask and notificationsTask keep running.
// If you cancel the outer CancellationToken, that only works if you remembered
// to pass it to every call. The other tasks are now orphaned.
```

The scope model removes the need for that discipline. The structure of the code — the block boundaries — *is* the lifetime contract.

::: sidebar
**Why no "fire and forget"?** Fire-and-forget breaks both of the guarantees you want from structured concurrency. When a scope exits, you want to know all work is done — fire-and-forget means "some work might still be running somewhere." When an error occurs, you want sibling work cancelled — a detached task cannot participate in that. If you genuinely need a background task that outlives the scope — a long-running worker, a background indexer — that is an architectural decision. Model it as a dedicated service object with an explicit lifecycle, not a detached task that slipped out of a scope.
:::

## §10.4 Protected types

Protected types are how Lyric handles shared mutable state. The model comes from Ada: a `protected type` wraps state with structurally-enforced mutual exclusion. There is no way to read or write the state without going through a declared operation.

```lyric
protected type BoundedQueue[T] {
  var items: array[100, T]
  var count: Nat range 0 ..= 100

  invariant: count <= 100

  entry put(item: in T)
    when: count < 100
  {
    items[count] = item
    count += 1
  }

  entry take(): T
    when: count > 0
  {
    count -= 1
    return items[count]
  }
}
```

The key rules:

- `entry` operations are mutually exclusive. Only one runs at a time, regardless of how many callers are waiting.
- A `when:` clause is a barrier condition. A caller blocks until the condition is true. When `put` is called on a full queue, the caller does not spin and does not get an error — it waits until space is available.
- The `invariant:` is checked after every `entry` returns. If your operation leaves the state in an invariant-violating condition, the program terminates. This is intentional: an invariant violation in a protected type is an unrecoverable bug, not a recoverable error.
- The state inside the protected type is inaccessible from outside. There is no field access, no reflection, no way to reach around the interface.

Here is the token-bucket rate limiter from the worked examples. The `acquire` entry shows the barrier pattern in a realistic setting:

```lyric
pub protected type TokenBucket {
  var tokens: Double
  var lastRefill: Instant
  let capacity: Double
  let refillPerSecond: Double

  invariant: tokens >= 0.0 and tokens <= capacity

  pub entry acquire(count: in Double, clock: in Clock): Unit
    requires: count > 0.0
    requires: count <= capacity
    when: tokens >= count or
          durationBetween(lastRefill, clock.now()) >= secondsToRefillTo(count)
  {
    refill()
    tokens = tokens - count
  }

  // ... refill() and secondsToRefillTo() omitted for brevity
}
```

The `when:` condition says: block until enough tokens are available, or until enough time has elapsed that a refill would cover the request. The caller does not implement polling, does not manage a condition variable, and cannot accidentally skip the check. The barrier is part of the type's interface, not a convention layered on top.

Multiple callers contend safely. The mutual exclusion is structural — not a lock you remember to acquire, but a property of every operation on the type.

## §10.5 No raw locks

There is no `Monitor.Enter`, no `lock` statement, and no `SemaphoreSlim` you can reach for directly in normal Lyric code. If you need them — and this is unusual — you use an `@axiom` boundary to call into .NET primitives:

```lyric
@axiom
extern package System.Threading {
  type SemaphoreSlim
  func makeSemaphore(initial: in Int, max: in Int): SemaphoreSlim
  async func waitAsync(sem: in SemaphoreSlim): Unit
  func release(sem: in SemaphoreSlim): Unit
}
```

The friction is intentional. Every use of raw synchronisation is visible in code review, appears in `@axiom` boundaries that are auditable, and is listed in the package's contract metadata. If you want to understand all the places a codebase reaches for raw locking, you look for `@axiom` blocks — not a grep for the word "lock" scattered across hundreds of files.

In practice, `protected type` covers the vast majority of shared-state patterns. The token bucket, the bounded queue, a shared cache, a rate limiter, a connection pool — all of these fit the model.

## §10.6 `defer`

`defer` runs a block when the enclosing scope exits, regardless of how it exits — normal return, early return, or exception:

```lyric
async func fetchOne(url: in String, sem: in Semaphore): PageResult {
  await sem.acquire()
  defer { sem.release() }    // runs on scope exit, success or failure

  return match await client.get(url) {
    case Ok(response) -> PageResult(url = url, statusCode = Some(response.statusCode), ...)
    case Err(error)   -> PageResult(url = url, error = Some(error.message()), ...)
  }
}
```

Without `defer`, you would need to call `sem.release()` at every return point and in every catch block. With `defer`, you write the cleanup once, adjacent to the acquisition, and the compiler guarantees it runs.

`defer` is particularly useful for:

- Releasing semaphores and locks after acquisition
- Closing files and connections
- Recording metrics that must fire on every path (latency timers, error counters)
- Any cleanup that should not be skipped under any exit condition

Multiple `defer` blocks in the same scope execute in reverse declaration order — last declared, first executed — which matches the typical resource-release pattern.

## Exercises

1. Write two async functions `fetchA()` and `fetchB()`, each returning a `String`. Run them in a `scope` block and collect both results. Add `println` calls before and after each `await` and observe that the print order is not sequential — the tasks are running in parallel.

2. Add a `cancellation.checkOrThrow()` call inside a long-running async loop that processes a large slice. Write a test that cancels the operation after a short delay and verify that the loop stops before processing all items.

3. Implement a `protected type Counter` with an `entry increment(): Unit` and a regular `func get(): Int`. Create two concurrent tasks, each calling `increment` 100 times, and assert in a test that the final value is 200. Notice that you did not need a lock.

4. Add a `when:` barrier to a `protected type Latch` — an entry `fire()` that only executes once an internal `armed: Bool` flag is set by a separate `entry arm(): Unit`. Think through the state transitions: what happens if `fire` is called before `arm`? What does the invariant look like?

5. The `defer` block runs even on an early `return`. Write a function that has three early return points — one near the top, one in the middle, one at the bottom — and verify via `println` that the `defer` block runs in all three cases. Then confirm it also runs when the function raises a `Bug`.
