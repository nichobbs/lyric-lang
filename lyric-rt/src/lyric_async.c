/* lyric_async.c — the async task scheduler (Phase 2, stage B1; multi-threaded mode: docs/67 G8).
 *
 * Tasks are HOT: calling an async function runs its body (the LLVM
 * coroutine ramp) until the first genuine suspension — an await on an
 * incomplete task, or an async sleep — matching .NET's hot-task model.
 * A task that never suspends completes inside the ramp and no scheduling
 * happens at all, which is exactly the pre-coroutine passthrough
 * behavior (D-N-019/D-N-021).
 *
 * Two modes, chosen once per process by LYRIC_ASYNC_THREADS:
 *
 *   unset or 1  cooperative, single-threaded, run-to-completion
 *               (06-async-design.md, D-N-021's async-leaf follow-up).
 *               No lock is ever taken and nothing about the pre-G8
 *               behavior changes.
 *   N >= 2      N-1 worker threads plus every thread blocked in
 *               lyric_task_block_on run ready tasks from one shared FIFO
 *               queue.  A `spawn` call site raises a thread-local hint;
 *               the callee's prologue (lyric_task_defer_start) consumes
 *               it and queues the task instead of running its body on the
 *               spawner, so spawned tasks run in parallel with their
 *               spawner and with each other.  A plain (awaited) call
 *               stays hot on the calling thread.  See D214 for the proof
 *               obligations and the sanitizer evidence.
 *
 * State machine (a task is in at most one queue at a time):
 *
 *     RUNNING  — its frame is being executed right now (ramp or resume)
 *     SLEEPING — parked in the deadline-ordered sleeper list
 *     WAITING  — parked on another task's waiter list
 *     READY    — in the FIFO ready queue (woken, not yet resumed)
 *     COMPLETE — result slot valid; waiters have been moved to READY
 *
 * After an async call returns to its caller, its task is COMPLETE,
 * SLEEPING, or WAITING — never READY or RUNNING — so `spawn` needs no
 * scheduler call: it is just the call itself, with the returned task
 * held un-awaited.  (Multi-threaded mode: a deferred spawn is READY, or
 * already running on a worker.)
 *
 * Multi-threaded mode, the load-bearing rules:
 *
 *   1. One mutex (g_mu) guards the ready queue, the sleeper list, every
 *      waiter list and every task's `next` link, `state` writes, `result`
 *      writes, g_running, g_idle and g_host_pending.  `state` is atomic so
 *      lyric_task_is_complete / lyric_task_result read it without the lock;
 *      the COMPLETE store is a release that publishes `result`.
 *   2. A coroutine must not be resumed by another thread before it has
 *      finished suspending.  LLVM stores the resume index at the suspend
 *      point, AFTER the registration call (lyric_async_await/sleep), so a
 *      registration that became visible at once could be resumed while the
 *      suspending thread is still writing the frame.  Registration is
 *      therefore two-phase: the call only records the intent on the task
 *      (park_kind/park_dep) and in a thread-local slot; the thread
 *      publishes it (settle_pending) once the coroutine function has
 *      returned: after the resume in run_one, after the ramp
 *      (lyric_ramp_done, emitted after every async call) or at the next
 *      scheduler entry on that thread.
 *   3. A task's frame stays alive while it runs: the registration's
 *      scheduler ref is held until the stretch ends (run_one releases it),
 *      so an awaiter that wakes on another thread and drops the task
 *      cannot destroy a frame its completer is still leaving.
 *   4. g_running counts tasks mid-stretch (ramp or resume, not yet
 *      completed or settled).  A thread blocked in lyric_task_block_on
 *      reports a deadlock only when nothing is ready, sleeping or running
 *      anywhere.
 *   5. Task refcounts, the weak counts and protected-type monitors are
 *      already atomic or lock-guarded.  Collections and plain record
 *      fields are not: tasks that run in parallel may share them only
 *      through protected types (or not mutate them).
 *
 * Frame resumption goes through `lyric_coro_resume`/`lyric_coro_destroy`,
 * extern symbols DEFINED BY GENERATED IR (thin `llvm.coro.resume`/
 * `llvm.coro.destroy` wrappers).  CoroSplit emits the frame's resume and
 * destroy function pointers as `internal fastcc`, so C must not call
 * them directly through the frame — the wrapper compiled by LLVM gets
 * the calling convention right by construction.  The C unit tests
 * define fake wrappers over function-pointer handles instead.
 *
 * Reference counting: the caller of an async function owns the task ref
 * the ramp returns (rc = 1 at birth).  The scheduler holds exactly one
 * additional ref from the moment a task registers (SLEEPING/WAITING —
 * retained there) until the resume in which it completes.  A task's
 * destructor destroys its coroutine frame and releases a ref-typed
 * result.
 */
#if defined(__linux__) || defined(__wasi__)
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include <stdlib.h>

/* Defined by generated LLVM IR in async programs (thin llvm.coro.*
 * wrappers); defined by the test harness for the C unit tests. */
extern void lyric_coro_resume(void* hdl);
extern void lyric_coro_destroy(void* hdl);

enum {
    LYRIC_TASK_RUNNING = 0,
    LYRIC_TASK_SLEEPING = 1,
    LYRIC_TASK_WAITING = 2,
    LYRIC_TASK_READY = 3,
    LYRIC_TASK_COMPLETE = 4,
    LYRIC_TASK_HOST = 5, /* pending on the host; in no queue (lyric_host_task_new) */
};

/* A registration recorded by the running coroutine, published by its thread
 * once the coroutine function has returned (multi-threaded mode, rule 2). */
enum {
    PARK_NONE = 0,
    PARK_AWAIT = 1, /* park on park_dep's waiter list */
    PARK_SLEEP = 2, /* park in the sleeper list at wake_deadline_ns */
    PARK_YIELD = 3, /* deferred spawn start: straight to the ready queue */
};

#define MAX_ASYNC_THREADS 256

/* Scheduler queues.  Guarded by g_mu in multi-threaded mode; in the default
 * single-threaded mode nothing else touches them and no lock is taken. */
static LyricTask* g_ready_head = NULL;
static LyricTask* g_ready_tail = NULL;
static LyricTask* g_sleepers = NULL; /* singly linked, deadline-ascending */
static int64_t g_host_pending = 0;   /* host tasks created and not yet finished */

/* Multi-threaded mode.  g_mt is written once, by sched_init, before any
 * second thread exists; it is atomic so a thread that reaches the scheduler
 * through some other synchronisation edge still reads it race-free. */
static _Atomic int g_inited = 0;
static _Atomic int g_mt = 0;
static void* g_mu = NULL;     /* lyric_mutex slot (a reentrant monitor) */
static void* g_cv = NULL;     /* idle threads wait here */
static int32_t g_idle = 0;    /* threads waiting on g_cv; guarded by g_mu */
static int64_t g_running = 0; /* tasks mid-stretch; guarded by g_mu */

static _Thread_local LyricTask* tl_current = NULL; /* task whose frame is executing on this thread */
static _Thread_local LyricTask* tl_pending = NULL; /* recorded registration awaiting publication */
static _Thread_local int tl_spawn_hint = 0;

static inline int mt(void) {
    return atomic_load_explicit(&g_mt, memory_order_acquire);
}

static inline void sched_lock(void) {
    if (mt()) {
        lyric_mutex_lock(g_mu);
    }
}

static inline void sched_unlock(void) {
    if (mt()) {
        lyric_mutex_unlock(g_mu);
    }
}

static inline int32_t state_of(LyricTask* t) {
    return atomic_load_explicit(&t->state, memory_order_acquire);
}

static inline void set_state(LyricTask* t, int32_t s) {
    atomic_store_explicit(&t->state, s, memory_order_release);
}

static void* async_worker_main(void* arg);

/* LYRIC_ASYNC_THREADS: an integer >= 1; anything else (or unset) is 1. */
static int detect_async_threads(void) {
#if defined(__wasi__)
    return 1;
#else
    const char* env = getenv("LYRIC_ASYNC_THREADS");
    if (env && *env) {
        char* end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && *end == '\0' && v >= 1) {
            return v > MAX_ASYNC_THREADS ? MAX_ASYNC_THREADS : (int)v;
        }
    }
    return 1;
#endif
}

static void sched_init(void) {
    int n = detect_async_threads();
    if (n >= 2) {
        g_mu = lyric_alloc((uint64_t)lyric_mutex_size());
        lyric_mutex_init(g_mu);
        g_cv = lyric_alloc((uint64_t)lyric_cond_size());
        lyric_cond_init(g_cv);
        atomic_store_explicit(&g_mt, 1, memory_order_release);
        for (int i = 1; i < n; i++) {
            if (lyric_thread_spawn_detached(async_worker_main, NULL) != 0) {
                break; /* run with the workers that started; block_on callers always help */
            }
        }
    }
}

/* Every entry that can be the first scheduler call in a process goes through
 * here.  The global lock serialises two threads racing to start the scheduler. */
static inline void sched_ensure(void) {
    if (atomic_load_explicit(&g_inited, memory_order_acquire)) {
        return;
    }
    lyric_global_lock();
    if (!atomic_load_explicit(&g_inited, memory_order_relaxed)) {
        sched_init();
        atomic_store_explicit(&g_inited, 1, memory_order_release);
    }
    lyric_global_unlock();
}

int32_t lyric_async_threads(void) {
    sched_ensure();
    return mt() ? 1 : 0;
}

static void lyric_task_dtor(void* obj) {
    LyricTask* t = (LyricTask*)obj;
    if (t->coro_handle) {
        lyric_coro_destroy(t->coro_handle);
        t->coro_handle = NULL;
    }
    /* Tri-state result ownership (#5545): 0 scalar, 1 strong ref, 2 weak
     * ref — a weak task result must release via the weak-count variant
     * so it never keeps its target strongly alive. */
    if (t->result_is_ref == 1 || t->result_is_ref == 3) {
        lyric_release((void*)(intptr_t)t->result);
    } else if (t->result_is_ref == 2) {
        lyric_weak_release((void*)(intptr_t)t->result);
    }
}

static LyricTask* task_alloc(void* coro_handle) {
    LyricTask* t = (LyricTask*)lyric_alloc(sizeof(LyricTask));
    atomic_store_explicit(&t->rc, 1, memory_order_relaxed);
    atomic_store_explicit(&t->weak, 1, memory_order_relaxed);
    t->dtor = lyric_task_dtor;
    t->coro_handle = coro_handle;
    atomic_store_explicit(&t->state, LYRIC_TASK_RUNNING, memory_order_relaxed);
    t->result = 0;
    t->result_is_ref = 0;
    t->wake_deadline_ns = 0;
    t->waiters = NULL;
    t->next = NULL;
    t->park_kind = PARK_NONE;
    t->park_dep = NULL;
    return t;
}

static void settle_pending(void);

LyricTask* lyric_task_new(void* coro_handle) {
    sched_ensure();
    LyricTask* t = task_alloc(coro_handle);
    if (mt()) {
        settle_pending();
        sched_lock();
        g_running++; /* the ramp stretch; ended by complete or by settle */
        sched_unlock();
    }
    return t;
}

int32_t lyric_task_is_complete(LyricTask* t) {
    return state_of(t) == LYRIC_TASK_COMPLETE ? 1 : 0;
}

/* Raw 64-bit result slot; does NOT retain a ref-typed result (the
 * kernel-read-is-a-borrow convention shared with lyric_list_get). */
int64_t lyric_task_result(LyricTask* t) {
    if (state_of(t) != LYRIC_TASK_COMPLETE) {
        lyric_panic_msg("await read on an incomplete task (scheduler bug)", "lyric_async.c", __LINE__);
    }
    if (t->result_is_ref == 3) {
        /* A host operation that failed: the message is the host's own. */
        lyric_panic_msg((const char*)LYRIC_STRING_DATA((LyricString*)(intptr_t)t->result), "host operation",
                        __LINE__);
    }
    return t->result;
}

LyricTask* lyric_current_task(void) {
    return tl_current;
}

void lyric_set_current_task(LyricTask* t) {
    tl_current = t;
}

/* ── Queues (g_mu held in multi-threaded mode) ───────────────────────── */

static void ready_push(LyricTask* t) {
    set_state(t, LYRIC_TASK_READY);
    t->next = NULL;
    if (g_ready_tail) {
        g_ready_tail->next = t;
    } else {
        g_ready_head = t;
    }
    g_ready_tail = t;
    if (mt() && g_idle > 0) {
        lyric_cond_broadcast(g_cv);
    }
}

/* Pops the oldest ready task and flips it to RUNNING; counts it as running
 * in multi-threaded mode (the stretch ends in complete or settle). */
static LyricTask* ready_pop(void) {
    LyricTask* t = g_ready_head;
    if (t) {
        g_ready_head = t->next;
        if (!g_ready_head) {
            g_ready_tail = NULL;
        }
        t->next = NULL;
        set_state(t, LYRIC_TASK_RUNNING);
        if (mt()) {
            g_running++;
        }
    }
    return t;
}

/* Deadline-ascending insertion into the sleeper list. */
static void sleepers_insert(LyricTask* t) {
    set_state(t, LYRIC_TASK_SLEEPING);
    LyricTask** slot = &g_sleepers;
    while (*slot && (*slot)->wake_deadline_ns <= t->wake_deadline_ns) {
        slot = &(*slot)->next;
    }
    t->next = *slot;
    *slot = t;
}

/* Appended at the TAIL so completion wakes waiters in registration order
 * (FIFO fairness, #5082); waiter lists are short, so the walk is cheap. */
static void waiters_append(LyricTask* dep, LyricTask* waiter) {
    set_state(waiter, LYRIC_TASK_WAITING);
    waiter->next = NULL;
    LyricTask** slot = &dep->waiters;
    while (*slot) {
        slot = &(*slot)->next;
    }
    *slot = waiter;
}

static void wake_waiters(LyricTask* t) {
    LyricTask* w = t->waiters;
    t->waiters = NULL;
    while (w) {
        LyricTask* next = w->next;
        ready_push(w); /* waiter keeps the sched ref it acquired at registration */
        w = next;
    }
}

/* Publish the registration the running coroutine recorded, now that its
 * function has returned and the frame is fully suspended (rule 2).  Ends the
 * task's stretch. */
static void settle_pending(void) {
    LyricTask* t = tl_pending;
    if (!t) {
        return;
    }
    tl_pending = NULL;
    lyric_mutex_lock(g_mu);
    switch (t->park_kind) {
    case PARK_AWAIT: {
        LyricTask* dep = t->park_dep;
        if (state_of(dep) == LYRIC_TASK_COMPLETE) {
            ready_push(t); /* the dependency finished while this task was suspending */
        } else {
            waiters_append(dep, t);
        }
        break;
    }
    case PARK_SLEEP:
        sleepers_insert(t);
        if (g_idle > 0) {
            lyric_cond_broadcast(g_cv); /* a new earliest deadline: re-time the idle waiters */
        }
        break;
    case PARK_YIELD:
        ready_push(t);
        break;
    default:
        lyric_panic_msg("settle of a task with no recorded registration (scheduler bug)", "lyric_async.c", __LINE__);
    }
    t->park_kind = PARK_NONE;
    t->park_dep = NULL;
    g_running--;
    lyric_mutex_unlock(g_mu);
}

/* Completion: store the result (ownership of a ref-typed result
 * transfers to the task), wake every waiter, drop the scheduler's ref
 * if one was held.  Called by the coroutine body just before its final
 * suspend — including hot completion inside the ramp, where the task
 * never registered and no scheduler ref exists.  Calling it on an
 * already-COMPLETE task panics. */
void lyric_task_complete(LyricTask* t, int64_t result, int32_t result_is_ref) {
    if (mt()) {
        settle_pending();
    }
    sched_lock();
    int32_t st = state_of(t);
    if (st == LYRIC_TASK_COMPLETE) {
        lyric_panic_msg("task completed twice (scheduler bug)", "lyric_async.c", __LINE__);
    }
    /* lyric_task_complete only ever runs inside a coroutine body, which
     * only executes while its task is RUNNING (the ramp, or a resume
     * that run_one already flipped to RUNNING) or re-registers itself
     * (SLEEPING/WAITING) before returning — READY means "queued, not yet
     * resumed," which is not a state a running body can observe itself
     * in, so it is deliberately excluded here. */
    int had_sched_ref = st == LYRIC_TASK_SLEEPING || st == LYRIC_TASK_WAITING;
    t->result = result;
    t->result_is_ref = result_is_ref;
    set_state(t, LYRIC_TASK_COMPLETE);
    wake_waiters(t);
    if (mt()) {
        g_running--;
        if (g_idle > 0) {
            lyric_cond_broadcast(g_cv); /* a block_on caller may be waiting for exactly this task */
        }
    }
    sched_unlock();
    if (had_sched_ref) {
        lyric_release(t);
    }
}

/* ── Host-finished tasks (docs/35 section 11) ────────────────────────── */

LyricTask* lyric_host_task_new(void) {
    sched_ensure();
    LyricTask* t = task_alloc(NULL);
    set_state(t, LYRIC_TASK_HOST);
    lyric_retain(t); /* the host's ref, dropped by finish/fail */
    sched_lock();
    g_host_pending++;
    sched_unlock();
    return t;
}

/* Complete a pending host task and wake what awaits it. */
static void host_task_settle(LyricTask* t, int64_t result, int32_t result_is_ref) {
    sched_lock();
    if (state_of(t) != LYRIC_TASK_HOST) {
        lyric_panic_msg("host task finished twice, or is not a host task", "lyric_async.c", __LINE__);
    }
    t->result = result;
    t->result_is_ref = result_is_ref;
    set_state(t, LYRIC_TASK_COMPLETE);
    g_host_pending--;
    wake_waiters(t); /* the waiters keep the sched ref they took when they parked */
    if (mt() && g_idle > 0) {
        lyric_cond_broadcast(g_cv);
    }
    sched_unlock();
    lyric_release(t); /* the host's ref */
}

void lyric_host_task_finish(LyricTask* t, int64_t result, int32_t result_is_ref) {
    host_task_settle(t, result, result_is_ref);
}

void lyric_host_task_fail(LyricTask* t, LyricString* message) {
    host_task_settle(t, (int64_t)(intptr_t)message, 3);
}

int64_t lyric_host_tasks_pending(void) {
    sched_lock();
    int64_t n = g_host_pending;
    sched_unlock();
    return n;
}

/* ── Registration (called by the running coroutine, then it suspends) ── */

/* Register the currently-RUNNING task as awaiting `dep`; the caller
 * must suspend immediately after.  Single-threaded: panics if dep is
 * already complete (codegen checks is_complete first and skips the
 * suspend).  Multi-threaded: dep can complete between that check and the
 * suspend, so the registration is only recorded here and published after
 * the coroutine returns, where a finished dep sends the waiter straight
 * back to the ready queue. */
void lyric_async_await(LyricTask* waiter, LyricTask* dep) {
    if (mt()) {
        settle_pending();
        lyric_retain(waiter); /* the sched ref, held while parked */
        waiter->park_kind = PARK_AWAIT;
        waiter->park_dep = dep;
        tl_pending = waiter;
        return;
    }
    if (state_of(dep) == LYRIC_TASK_COMPLETE) {
        lyric_panic_msg("await registration on a complete task (codegen bug)", "lyric_async.c", __LINE__);
    }
    lyric_retain(waiter);
    waiters_append(dep, waiter);
}

/* Register the currently-RUNNING task as sleeping for `ms`; the caller
 * must suspend immediately after. */
void lyric_async_sleep(LyricTask* t, int64_t ms) {
    if (ms < 0) {
        ms = 0;
    }
    if (mt()) {
        settle_pending();
    }
    lyric_retain(t); /* the sched ref, held while parked */
    /* Saturate instead of overflowing int64 nanoseconds (#5083): a
     * deadline this far out (~292 years) is "never" in practice, and a
     * wrapped negative deadline would wake the sleeper immediately. */
    int64_t now = lyric_monotonic_nanos();
    if (ms > (INT64_MAX - now) / 1000000) {
        t->wake_deadline_ns = INT64_MAX;
    } else {
        t->wake_deadline_ns = now + ms * 1000000;
    }
    if (mt()) {
        t->park_kind = PARK_SLEEP;
        tl_pending = t;
        return;
    }
    sleepers_insert(t);
}

/* `spawn` call sites raise the hint just before the call; the callee's
 * prologue consumes it.  Only meaningful with several scheduler threads. */
void lyric_spawn_hint(void) {
    if (mt()) {
        tl_spawn_hint = 1;
    }
}

/* Called by every async function's prologue after lyric_task_new.  Returns
 * 1 when the task must suspend at once so a worker starts its body (the
 * spawn hint was set and the scheduler is multi-threaded), else 0. */
int32_t lyric_task_defer_start(LyricTask* t) {
    int hinted = tl_spawn_hint;
    tl_spawn_hint = 0;
    if (!hinted || !mt()) {
        return 0;
    }
    lyric_retain(t); /* the sched ref, held while queued */
    t->park_kind = PARK_YIELD;
    tl_pending = t;
    return 1;
}

/* Emitted after every async call: the callee's ramp has returned, so a
 * registration it recorded is now safe to publish. */
void lyric_ramp_done(void) {
    if (mt()) {
        settle_pending();
    }
}

/* ── Driving ─────────────────────────────────────────────────────────── */

/* Move every sleeper whose deadline has passed to the ready queue;
 * returns the earliest still-pending deadline, or -1 if none. */
static int64_t wake_expired_sleepers(void) {
    int64_t now = lyric_monotonic_nanos();
    while (g_sleepers && g_sleepers->wake_deadline_ns <= now) {
        LyricTask* t = g_sleepers;
        g_sleepers = t->next;
        ready_push(t); /* keeps the sched ref it acquired at SLEEPING */
    }
    return g_sleepers ? g_sleepers->wake_deadline_ns : -1;
}

/* Resume a task popped by ready_pop (state RUNNING).  The sched ref is held
 * across the resume and settled afterwards — released here whether the task
 * completed (lyric_task_complete saw RUNNING, no double release) or
 * re-registered (registration took its own fresh ref). */
static void run_one(LyricTask* t) {
    LyricTask* prev = tl_current;
    tl_current = t;
    lyric_coro_resume(t->coro_handle);
    tl_current = prev;
    if (mt()) {
        if (t->park_kind == PARK_NONE && state_of(t) != LYRIC_TASK_COMPLETE) {
            lyric_panic_msg("coroutine suspended without registering (codegen bug)", "lyric_async.c", __LINE__);
        }
        settle_pending();
    } else if (state_of(t) == LYRIC_TASK_RUNNING) {
        lyric_panic_msg("coroutine suspended without registering (codegen bug)", "lyric_async.c", __LINE__);
    }
    lyric_release(t);
}

static void panic_no_progress(void) {
    if (g_host_pending > 0) {
        lyric_panic_msg(
            "awaiting a host operation inside a synchronous call: the host cannot finish it until this call "
            "returns, so make the caller an async func",
            "lyric_async.c", __LINE__);
    }
    lyric_panic_msg("deadlock: awaited task can never complete (no ready tasks, no timers)", "lyric_async.c",
                    __LINE__);
}

/* Multi-threaded drive loop, for the worker threads (root == NULL, never
 * returns) and for lyric_task_block_on (returns once `root` completes). */
static void sched_loop(LyricTask* root) {
    lyric_mutex_lock(g_mu);
    for (;;) {
        if (root && state_of(root) == LYRIC_TASK_COMPLETE) {
            break;
        }
        LyricTask* t = ready_pop();
        int64_t next_deadline = -1;
        if (!t) {
            next_deadline = wake_expired_sleepers();
            t = ready_pop();
        }
        if (t) {
            lyric_mutex_unlock(g_mu);
            run_one(t);
            lyric_mutex_lock(g_mu);
            continue;
        }
        if (root && next_deadline < 0 && g_running == 0) {
            panic_no_progress();
        }
        g_idle++;
        if (next_deadline >= 0) {
            int64_t wait_ns = next_deadline - lyric_monotonic_nanos();
            if (wait_ns > 0) {
                (void)lyric_cond_timedwait(g_cv, g_mu, wait_ns);
            }
        } else {
            lyric_cond_wait(g_cv, g_mu);
        }
        g_idle--;
    }
    lyric_mutex_unlock(g_mu);
}

static void* async_worker_main(void* arg) {
    (void)arg;
    sched_ensure();
    sched_loop(NULL);
    return NULL;
}

/* Drive the scheduler until `root` completes.  Entered from a
 * synchronous context: `main` awaiting the program's root task, or an
 * `await` in a plain (non-async) function. */
void lyric_task_block_on(LyricTask* root) {
    sched_ensure();
    if (mt()) {
        settle_pending();
        sched_loop(root);
        return;
    }
    for (;;) {
        if (state_of(root) == LYRIC_TASK_COMPLETE) {
            return;
        }
        LyricTask* t = ready_pop();
        if (t) {
            run_one(t);
            continue;
        }
        int64_t next_deadline = wake_expired_sleepers();
        if (g_ready_head) {
            continue;
        }
        if (next_deadline < 0) {
            panic_no_progress();
        }
        int64_t now = lyric_monotonic_nanos();
        int64_t wait_ns = next_deadline - now;
        lyric_sleep_nanos(wait_ns);
    }
}

/* Run every ready task (waking expired sleepers) until none is runnable, without
 * ever blocking, for hosts that own the event loop (the wasm `module` shape,
 * docs/35 §11).  Returns -1 when no task is READY or SLEEPING and no host
 * operation is pending, -2 when none is but a host operation is, else the
 * nanoseconds until the earliest sleeper wakes (0 when one is already due).
 * Single-threaded scheduler only. */
int64_t lyric_sched_poll(void) {
    sched_ensure();
    if (mt()) {
        lyric_panic_msg("lyric_sched_poll needs the single-threaded scheduler (unset LYRIC_ASYNC_THREADS)",
                        "lyric_async.c", __LINE__);
    }
    for (;;) {
        LyricTask* t = ready_pop();
        if (t) {
            run_one(t);
            continue;
        }
        int64_t next_deadline = wake_expired_sleepers();
        if (g_ready_head) {
            continue;
        }
        if (next_deadline < 0) {
            return g_host_pending > 0 ? -2 : -1;
        }
        int64_t wait_ns = next_deadline - lyric_monotonic_nanos();
        return wait_ns > 0 ? wait_ns : 0;
    }
}
