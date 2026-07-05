# 06 — Async Design (LLVM Coro)

Async/await for the native backend is **Phase 2 implementation**. This document
fully specifies the mechanism so that Phase 2 agents have no design work to do.

**Status (D-N-022): SHIPPED.** The coroutine mechanism below is now the
shipped lowering: every non-generator `async func` emits as a
`presplitcoroutine` LLVM coroutine returning its `LyricTask*`, the
cooperative single-threaded scheduler lives in
`lyric-rt/src/lyric_async.c` (hot tasks, FIFO ready queue,
deadline-ordered timer list, `lyric_task_block_on` drive loop), and the
first async leaf primitive is `Std.Time.sleepMillis` intercepted inside
coroutine bodies (`lyric_async_sleep` + suspend; synchronous contexts
keep the blocking kernel twin). Spawned tasks genuinely interleave —
verified by effect-order tests in `llvm_self_test_async.l` under ASan.
Read D-N-019/D-N-021/D-N-022 in full before touching this area; the two
load-bearing verification findings remain: (1) freeing a coroutine's
frame from inside its own `resume()` without a prior `i1 true` final
suspend leaves the caller's handle dangling — the shipped epilogue
final-suspends and frees only on the destroy path; (2) CoroSplit emits
the frame's resume/destroy pointers as `internal fastcc`, so the C
scheduler resumes through `lyric_coro_resume`/`lyric_coro_destroy`
wrapper defines emitted into async-using modules, never through the
frame directly. Departures from the sketches below: the shipped
`LyricTask` stores a single `int64_t` result slot + `result_is_ref`
flag (not a `T`-sized inline payload), `spawn` involves no scheduler
call at all (hot tasks self-register only when they suspend), await
auto-unwraps at every non-`spawn` call site (matching the
type-transparent front end), and there is no `Std.Async` module — the
async leaf is the intercepted `Std.Time.sleepMillis`. Async generators
(`yield` in `async func`) remain N0099-rejected. Cancellation remains
out of scope (D-N-003: panics abort). The first async I/O leaf shipped
in D-N-023: in-coroutine `Std.Process.runCapture` drives a nonblocking
lyric-rt capture op through the sleep leaf (1 ms pump cadence, the JVM
kernel twin's documented idiom), honoring `timeoutMs`; D-N-024
extended the leaf to `runCaptureWithInput` (the op pumps stdin content
out through a nonblocking pipe) and brought the synchronous runner to
the same stdin/timeout parity. `poll()`-based fd readiness in the
scheduler is deferred to the socket leaf, where per-task pump cadences
stop scaling.

---

## Chosen mechanism: LLVM coro.* stackless coroutines

Lyric's `async func` / `await` map to LLVM's built-in coroutine intrinsics.
This is the same conceptual model as the MSIL `IAsyncStateMachine` and JVM async
state machine, but the state machine synthesis is delegated to LLVM's `CoroSplit`
optimization pass rather than being hand-synthesised in the compiler.

LLVM coro intrinsics work by:
1. The compiler emits the async function body as a single flat function with
   `llvm.coro.begin`, `llvm.coro.suspend`, and `llvm.coro.end` markers.
2. The `CoroSplit` pass (enabled at `-O1` or higher, or explicitly at `-O0` with
   `-coro-split`) splits this function into three functions:
   - **Ramp**: the initial entry; allocates the frame, runs until first suspend.
   - **Resume**: called to continue from a suspend point; runs until next suspend.
   - **Destroy**: frees the coroutine frame without resuming.
3. The coroutine **frame** (analogous to the IAsyncStateMachine struct) is allocated
   by LLVM using `llvm.coro.size` and a call to the user-supplied allocator.

---

## Lyric async model for native target

### `async func` return type

On native, an `async func f(...): T` returns a `Task[T]`. The `Task[T]` type is:

```lyric
// lyric-rt/lyric_async.h (C side):
typedef struct LyricTask {
    LyricObjectHeader header;     // rc + dtor
    void* coro_handle;            // LLVM coro handle (i8*)
    bool is_complete;
    LyricObjectHeader* result;    // the T value (or null if incomplete/void)
    // linked list for the scheduler queue
    struct LyricTask* next;
} LyricTask;
```

```lyric
// Lyric type:
pub opaque type Task[T] = ...    // wraps LyricTask*
```

### `await` lowering

`await expr` where `expr: Task[T]`:

```llvm
; Conceptual lowering of:
;   val result = await someAsyncFunc()

; 1. Get the Task* from the callee
%task = call i8* @someAsyncFunc(...)   ; task starts "running" (see scheduler)

; 2. Suspend this coroutine, transferring control to the scheduler
;    The scheduler will resume this coroutine when the task completes.
%suspend_result = call i8 @llvm.coro.suspend(token %coro_token, i1 false)
; suspend_result: 0=resume, 1=destroy (coroutine cancelled)
switch i8 %suspend_result, label %resume [i8 1, label %cleanup]

resume:
; 3. Load the result from the completed task
%result_ptr = call i8* @lyric_task_result(i8* %task)
%result = bitcast i8* %result_ptr to %T*
; release the task now that we've consumed it
call void @lyric_release(i8* %task)
```

### The scheduler protocol

`lyric-rt` provides a minimal run-to-completion scheduler:

```c
// lyric-rt/src/lyric_async.c

// Run the event loop until all tasks complete.
void lyric_runtime_run(void);

// Spawn a new top-level task.
LyricTask* lyric_async_spawn(void* coro_handle);

// Called from within a coroutine to register a dependency on another task.
// The current coroutine is suspended; it resumes when dependency completes.
void lyric_async_await_task(void* current_coro, LyricTask* dependency);
```

The Phase 1 scheduler is **single-threaded** and **cooperative**. It runs a
simple queue of ready coroutines, driving each one step at a time:

```
ready_queue: [coro1, coro2, coro3]
wait_queue: {coro4 → waiting for coro1}

loop:
  pop coro from ready_queue
  resume(coro)                  // runs until next suspend or completion
  if coro completed:
    wake any coros waiting for it → move to ready_queue
  else:
    re-enqueue coro if self-suspended (e.g., yield)
```

Phase 2 can replace this with a work-stealing multi-threaded scheduler (like
Tokio's or Go's runtime) without changing the compiler's coro emission.

---

## Coroutine frame layout and ARC

The LLVM `CoroSplit` pass automatically identifies all local variables that are
live across at least one `llvm.coro.suspend` point and includes them in the
coroutine frame. The compiler does NOT need to manually compute the frame layout.

**ARC complication:** A reference-typed local variable that is live across a
suspend point must have its RC retained in the frame. Without explicit action,
the callee could release the object while the coroutine is suspended (if the
only reference was the local variable the coroutine saved to its frame).

The rule: **before every `llvm.coro.suspend`, retain all reference-typed locals
that are live after the suspend point.** This is an extension of the standard
ARC insertion rules.

```llvm
; val s: String = someString()
; ...
; await someTask()      ← suspend point
; Console.println(s)   ← s is used after the suspend

; Correct emission:
call void @lyric_retain(i8* %s_raw)    ; retain s before suspend
%r = call i8 @llvm.coro.suspend(...)
; ... after resume:
call void @lyric_console_println(i8* %s_raw)
call void @lyric_release(i8* %s_raw)   ; release at end of scope
```

The Phase 2 ARC-in-async pass will compute liveness at suspend points and insert
retains automatically, just as the standard ARC pass inserts retains/releases.

---

## Complete example: async HTTP fetch

```lyric
async func fetchUser(id: Int): Task[Option[User]] {
  val resp = await Http.get("https://api.example.com/users/" ++ id.toString())
  if resp.status == 200 {
    Some(parseUser(resp.body))
  } else {
    None
  }
}
```

LLVM IR shape (before CoroSplit, simplified):

```llvm
define i8* @fetchUser(i32 %id) {
entry:
  ; Coro setup
  %size = call i64 @llvm.coro.size.i64()
  %frame = call i8* @lyric_alloc(i64 %size)
  %hdl = call token @llvm.coro.begin(token none, i8* %frame)

  ; Build URL string
  %id_str = call i8* @Std.Int.toString(i32 %id)
  %base   = bitcast { i32, i8*, i64, i64 }* @.strobj.base_url to i8*
  %url    = call i8* @lyric_string_concat(i8* %base, i8* %id_str)
  call void @lyric_release(i8* %id_str)

  ; Spawn Http.get task
  %task = call i8* @Std.Http.get(i8* %url)
  call void @lyric_release(i8* %url)

  ; Retain task before suspend (live across suspend)
  call void @lyric_retain(i8* %task)

  ; Suspend point (await)
  %s0 = call i8 @llvm.coro.suspend(token %hdl, i1 false)
  switch i8 %s0, label %resume0 [i8 1, label %cleanup]

resume0:
  ; Use task result
  %resp  = call i8* @lyric_task_result(i8* %task)
  call void @lyric_release(i8* %task)
  ; ... parse and return ...
  %result = ...
  call void @llvm.coro.end(i8* %hdl, i1 false)
  ret i8* %result

cleanup:
  call void @lyric_release(i8* %task)   ; clean up retained task
  call void @llvm.coro.end(i8* %hdl, i1 true)
  ret i8* null
}
```

After `CoroSplit`, this becomes three functions: `fetchUser.ramp`,
`fetchUser.resume`, `fetchUser.destroy`.

---

## `lyric.toml` integration for async

No manifest changes are needed for async. `Task[T]` is part of `Std.Async`, which
is a normal Lyric stdlib package. It is only available on the native target when
`--target native` and when `lyric-rt` includes the scheduler (Phase 2).

---

## Phase 1 restriction

Phase 1 must emit a clear error for any `async func` targeting native:

```
N0099: `async func fetchUser` is not supported for --target native in Phase 1.
       Async functions for the native target are planned for Phase 2.
       For now, use --target dotnet or --target jvm.
```

The error is emitted in `Llvm.Codegen.codegenFunc` when `decl.isAsync == true`.
It is a hard error (not a warning) — async functions targeting native do not
produce partial output.

---

## Phase 2 work items for async

The following items are scoped for Phase 2. They are listed here so agents can
plan ahead:

- **A-1:** Implement `lyric_runtime_run`, `lyric_async_spawn`, `lyric_async_await_task`
  in `lyric-rt/src/lyric_async.c`.
- **A-2:** Implement `Std.Async` (`Task[T]`, `spawn`, `await` sugar) as a native
  stdlib package.
- **A-3:** Extend `Llvm.Codegen.codegenFunc` to emit coro.* intrinsics for `async func`.
- **A-4:** Extend ARC insertion pass (`Llvm.Arc`) to retain live reference-typed
  locals before each `llvm.coro.suspend`.
- **A-5:** Verify CoroSplit runs in the clang pipeline (it does at `-O1`+; at
  `-O0` it must be explicitly requested via `-Xclang -mllvm -Xclang -coro-split`
  or an equivalent pipeline flag).
- **A-6:** Write `llvm_self_test_async.l` covering: basic async function, chained
  awaits, async in a loop, async with captures (testing ARC-across-await).
- **A-7:** `lyric test` CI integration for async self-tests.
