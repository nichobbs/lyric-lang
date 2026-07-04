/* lyric_async.c — the async task scheduler (Phase 2, stage B1).
 *
 * Single-threaded, cooperative, run-to-completion (06-async-design.md,
 * D-N-021's async-leaf follow-up).  Tasks are HOT: calling an async
 * function runs its body (the LLVM coroutine ramp) until the first
 * genuine suspension — an await on an incomplete task, or an async
 * sleep — matching .NET's hot-task model.  A task that never suspends
 * completes inside the ramp and no scheduling happens at all, which is
 * exactly the pre-coroutine passthrough behavior (D-N-019/D-N-021).
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
 * held un-awaited.
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
#if defined(__linux__)
#define _POSIX_C_SOURCE 200809L
#endif

#include "lyric_rt.h"

#include <stddef.h>
#include <stdint.h>
#include <time.h>

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
};

/* Scheduler queues (single-threaded — no locking). */
static LyricTask* g_ready_head = NULL;
static LyricTask* g_ready_tail = NULL;
static LyricTask* g_sleepers = NULL; /* singly linked, deadline-ascending */
static LyricTask* g_current = NULL;  /* task whose frame is executing */

void lyric_task_dtor(void* obj) {
    LyricTask* t = (LyricTask*)obj;
    if (t->coro_handle) {
        lyric_coro_destroy(t->coro_handle);
        t->coro_handle = NULL;
    }
    if (t->result_is_ref) {
        lyric_release((void*)(intptr_t)t->result);
    }
}

LyricTask* lyric_task_new(void* coro_handle) {
    LyricTask* t = (LyricTask*)lyric_alloc(sizeof(LyricTask));
    atomic_store_explicit(&t->rc, 1, memory_order_relaxed);
    t->dtor = lyric_task_dtor;
    t->coro_handle = coro_handle;
    t->state = LYRIC_TASK_RUNNING;
    t->result = 0;
    t->result_is_ref = 0;
    t->wake_deadline_ns = 0;
    t->waiters = NULL;
    t->next = NULL;
    return t;
}

int32_t lyric_task_is_complete(LyricTask* t) {
    return t->state == LYRIC_TASK_COMPLETE ? 1 : 0;
}

/* Raw 64-bit result slot; does NOT retain a ref-typed result (the
 * kernel-read-is-a-borrow convention shared with lyric_list_get). */
int64_t lyric_task_result(LyricTask* t) {
    if (t->state != LYRIC_TASK_COMPLETE) {
        lyric_panic_msg("await read on an incomplete task (scheduler bug)", "lyric_async.c", __LINE__);
    }
    return t->result;
}

LyricTask* lyric_current_task(void) {
    return g_current;
}

void lyric_set_current_task(LyricTask* t) {
    g_current = t;
}

static void ready_push(LyricTask* t) {
    t->state = LYRIC_TASK_READY;
    t->next = NULL;
    if (g_ready_tail) {
        g_ready_tail->next = t;
    } else {
        g_ready_head = t;
    }
    g_ready_tail = t;
}

static LyricTask* ready_pop(void) {
    LyricTask* t = g_ready_head;
    if (t) {
        g_ready_head = t->next;
        if (!g_ready_head) {
            g_ready_tail = NULL;
        }
        t->next = NULL;
    }
    return t;
}

/* Completion: store the result (ownership of a ref-typed result
 * transfers to the task), wake every waiter, drop the scheduler's ref
 * if one was held.  Called by the coroutine body just before its final
 * suspend — including hot completion inside the ramp, where the task
 * never registered and no scheduler ref exists.  Calling it on an
 * already-COMPLETE task panics. */
void lyric_task_complete(LyricTask* t, int64_t result, int32_t result_is_ref) {
    if (t->state == LYRIC_TASK_COMPLETE) {
        lyric_panic_msg("task completed twice (scheduler bug)", "lyric_async.c", __LINE__);
    }
    int had_sched_ref = t->state == LYRIC_TASK_SLEEPING || t->state == LYRIC_TASK_WAITING ||
                        t->state == LYRIC_TASK_READY;
    t->result = result;
    t->result_is_ref = result_is_ref;
    t->state = LYRIC_TASK_COMPLETE;
    LyricTask* w = t->waiters;
    t->waiters = NULL;
    while (w) {
        LyricTask* next = w->next;
        ready_push(w); /* waiter keeps the sched ref it acquired at WAITING */
        w = next;
    }
    if (had_sched_ref) {
        lyric_release(t);
    }
}

/* Register the currently-RUNNING task as awaiting `dep`; the caller
 * must suspend immediately after.  Panics if dep is already complete
 * (codegen checks is_complete first and skips the suspend).  Appended
 * at the TAIL so completion wakes waiters in registration order (FIFO
 * fairness, #5082); waiter lists are short, so the walk is cheap. */
void lyric_async_await(LyricTask* waiter, LyricTask* dep) {
    if (dep->state == LYRIC_TASK_COMPLETE) {
        lyric_panic_msg("await registration on a complete task (codegen bug)", "lyric_async.c", __LINE__);
    }
    lyric_retain(waiter); /* the sched ref, held while parked */
    waiter->state = LYRIC_TASK_WAITING;
    waiter->next = NULL;
    LyricTask** slot = &dep->waiters;
    while (*slot) {
        slot = &(*slot)->next;
    }
    *slot = waiter;
}

/* Register the currently-RUNNING task as sleeping for `ms`; the caller
 * must suspend immediately after. */
void lyric_async_sleep(LyricTask* t, int64_t ms) {
    if (ms < 0) {
        ms = 0;
    }
    lyric_retain(t); /* the sched ref, held while parked */
    t->state = LYRIC_TASK_SLEEPING;
    /* Saturate instead of overflowing int64 nanoseconds (#5083): a
     * deadline this far out (~292 years) is "never" in practice, and a
     * wrapped negative deadline would wake the sleeper immediately. */
    int64_t now = lyric_monotonic_nanos();
    if (ms > (INT64_MAX - now) / 1000000) {
        t->wake_deadline_ns = INT64_MAX;
    } else {
        t->wake_deadline_ns = now + ms * 1000000;
    }
    /* Deadline-ascending insertion. */
    LyricTask** slot = &g_sleepers;
    while (*slot && (*slot)->wake_deadline_ns <= t->wake_deadline_ns) {
        slot = &(*slot)->next;
    }
    t->next = *slot;
    *slot = t;
}

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

static void run_one(LyricTask* t) {
    /* Leaving READY for RUNNING: the sched ref is held across the
     * resume and settled afterwards — released here whether the task
     * completed (lyric_task_complete saw RUNNING, no double release)
     * or re-registered (registration took its own fresh ref). */
    t->state = LYRIC_TASK_RUNNING;
    LyricTask* prev = g_current;
    g_current = t;
    lyric_coro_resume(t->coro_handle);
    g_current = prev;
    if (t->state == LYRIC_TASK_RUNNING) {
        lyric_panic_msg("coroutine suspended without registering (codegen bug)", "lyric_async.c", __LINE__);
    }
    lyric_release(t);
}

/* Drive the scheduler until `root` completes.  Entered from a
 * synchronous context: `main` awaiting the program's root task, or an
 * `await` in a plain (non-async) function. */
void lyric_task_block_on(LyricTask* root) {
    for (;;) {
        if (root->state == LYRIC_TASK_COMPLETE) {
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
            lyric_panic_msg("deadlock: awaited task can never complete (no ready tasks, no timers)", "lyric_async.c",
                            __LINE__);
        }
        int64_t now = lyric_monotonic_nanos();
        int64_t wait_ns = next_deadline - now;
        if (wait_ns > 0) {
            struct timespec ts;
            ts.tv_sec = (time_t)(wait_ns / 1000000000);
            ts.tv_nsec = (long)(wait_ns % 1000000000);
            nanosleep(&ts, NULL);
        }
    }
}
