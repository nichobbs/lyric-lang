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
 *   1           cooperative, single-threaded, run-to-completion
 *               (06-async-design.md, D-N-021's async-leaf follow-up).
 *               No lock is ever taken; ready tasks run in FIFO order.
 *   N >= 2      (unset: the processor count, D404) N-1 worker threads plus every thread blocked in
 *               lyric_task_block_on run ready tasks.  Each scheduler
 *               thread owns a work deque: it pushes and pops the newest
 *               end, idle threads steal the oldest end of another
 *               thread's deque (D217, D403).  A `spawn`
 *               call site raises a thread-local hint; the callee's
 *               prologue (lyric_task_defer_start) consumes it and queues
 *               the task on the spawner's deque instead of running its
 *               body on the spawner, so spawned tasks run in parallel
 *               with their spawner and with each other.  A plain
 *               (awaited) call stays hot on the calling thread.
 *
 * State machine (a task is in at most one queue at a time):
 *
 *     RUNNING  — its frame is being executed right now (ramp or resume)
 *     SLEEPING — parked in the deadline-ordered sleeper list
 *     WAITING  — parked on another task's waiter stack
 *     READY    — in a work deque or the injection queue (woken, not yet resumed)
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
 *   1. Placement.  A task made ready by a scheduler thread goes on that
 *      thread's deque (a spawn, a woken waiter, an expired sleeper), so the
 *      wake runs where its data is warm.  The owner pops the newest end;
 *      every FAIR_INTERVAL-th pop takes the oldest end and the injection
 *      queue first, so a task at the bottom of a busy deque is not starved
 *      when no thread is idle to steal it.  A thread that has no deque
 *      (more than MAX_DEQUES threads ever touched the scheduler) pushes to
 *      the shared injection queue under g_mu.  Each deque has its own small
 *      lock; g_mu guards only the injection queue, the sleeper list, the
 *      host-task count and idle parking.
 *   2. Waiters.  A task's waiter list is a lock-free stack (`waiters`).
 *      Completion swaps in the WAITERS_CLOSED sentinel and wakes what it
 *      took, oldest registration first (#5082); a registration whose push
 *      finds the sentinel sends the waiter straight to a deque.  `state` is
 *      atomic: lyric_task_is_complete / lyric_task_result read it without
 *      a lock; the COMPLETE store publishes `result`.
 *   3. A coroutine must not be resumed by another thread before it has
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
 *   4. A task's frame stays alive while it runs: the registration's
 *      scheduler ref is held until the stretch ends (run_one releases it),
 *      so an awaiter that wakes on another thread and drops the task
 *      cannot destroy a frame its completer is still leaving.
 *   5. g_active counts tasks that are READY or RUNNING (the `counted`
 *      flag says whether a task is in it).  Every transition adds before it
 *      subtracts (a completion adds its woken waiters before it removes
 *      itself), so g_active is never below the true count, and a transition
 *      between READY and RUNNING changes nothing.  A ramp that runs inside a
 *      resumed task (tl_busy) is not counted: the resumed task covers this
 *      thread until the ramp returns.  A thread blocked in lyric_task_block_on
 *      reports a deadlock only when g_active is zero and no task sleeps; the
 *      thread that takes g_active to zero wakes the idle threads so that
 *      check runs.
 *   6. Idle parking.  A thread with nothing to take searches (g_searching)
 *      for a few rounds, then stops searching, raises g_idle under g_mu and
 *      re-checks every deque, the injection queue and its root before it
 *      waits.  A thread that makes a task ready publishes it, then signals
 *      one parked thread under g_mu when nobody is searching and some thread
 *      is parked; a block_on caller marks its root `joined` so that root's
 *      completion wakes the parked threads.  Both sides use sequentially
 *      consistent operations, so one of them always sees the other and no
 *      wakeup is lost.  A spawn runs hot (no hand-off) when the spawner's
 *      deque already holds SPAWN_HOT_QUEUE tasks and no thread is idle or
 *      searching.
 *   7. Task refcounts, the weak counts and protected-type monitors are
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
 * additional ref from the moment a task registers (SLEEPING/WAITING/
 * READY — retained there) until the resume in which it completes.  A
 * task's destructor destroys its coroutine frame and releases a ref-typed
 * result.
 */
#if defined(__linux__) || defined(__wasi__)
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#endif

#include "lyric_rt.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>

#if !defined(_WIN32) && !defined(__wasi__)
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#endif

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
 * once the coroutine function has returned (multi-threaded mode, rule 3). */
enum {
    PARK_NONE = 0,
    PARK_AWAIT = 1, /* park on park_dep's waiter stack */
    PARK_SLEEP = 2, /* park in the sleeper list at wake_deadline_ns */
    PARK_YIELD = 3, /* deferred spawn start: straight to a deque */
    PARK_IO = 4,    /* park on the reactor until io_fd is ready or the deadline passes */
};

/* The waiter stack of a completed task: pushes that find it go to a deque. */
#define WAITERS_CLOSED ((LyricTask*)(uintptr_t)1)

#define MAX_ASYNC_THREADS 256
/* Deques for up to this many distinct threads (workers, block_on callers and
 * any other thread that makes a task ready); later threads use the injection
 * queue. */
#define MAX_DEQUES 512
/* An owner takes the oldest end (and looks at the injection queue first) on
 * every FAIR_INTERVAL-th pop. */
#define FAIR_INTERVAL 61
/* Rounds of stealing an idle worker tries, yielding between them, before it
 * parks on g_cv. */
#define IDLE_SPINS 16
/* A spawn runs hot on the spawner (as under the cooperative scheduler) when the
 * spawner's deque already holds this many stealable tasks and no thread is idle
 * or searching for work: queueing it would only add a hand-off. */
#define SPAWN_HOT_QUEUE 4
#define DEQUE_INITIAL_CAP 64

/* Scheduler queues.  In the default single-threaded mode the FIFO below is
 * the ready queue and nothing else touches it.  In multi-threaded mode it is
 * the injection queue, guarded by g_mu. */
static LyricTask* g_ready_head = NULL;
static LyricTask* g_ready_tail = NULL;
static _Atomic int64_t g_inject_n = 0;
static LyricTask* g_sleepers = NULL; /* singly linked, deadline-ascending; g_mu */
/* The reactor (#8494): tasks parked on a descriptor, singly linked through
 * `next` in no particular order; g_mu.  g_io_count is also read without the
 * lock as a hint.  At most one thread blocks in the poll at a time
 * (g_polling); the wake pipe interrupts it. */
static LyricTask* g_io_head = NULL;
static _Atomic int64_t g_io_count = 0;
static int g_polling = 0;
static int32_t g_cond_waiters = 0; /* threads in lyric_cond_wait/timedwait on g_cv; g_mu */
static _Atomic int64_t g_host_pending = 0; /* host tasks created and not yet finished */

/* Multi-threaded mode.  g_mt is written once, by sched_init, before any
 * second thread exists; it is atomic so a thread that reaches the scheduler
 * through some other synchronisation edge still reads it race-free. */
static _Atomic int g_inited = 0;
static _Atomic int g_mt = 0;
static void* g_mu = NULL;          /* lyric_mutex slot (a reentrant monitor) */
static void* g_cv = NULL;          /* idle threads wait here */
static _Atomic int32_t g_idle = 0; /* threads parked (or parking) on g_cv */
static _Atomic int32_t g_searching = 0; /* workers spinning over the deques for work */
static _Atomic int64_t g_active = 0; /* READY + RUNNING tasks (rule 5) */

typedef struct WorkDeque {
    void* mu;                /* lyric_mutex slot */
    LyricTask** buf;         /* ring of `cap` slots, cap a power of two */
    int64_t cap;
    int64_t head;            /* oldest */
    int64_t tail;            /* one past the newest */
    _Atomic int64_t n;       /* tail - head, readable without the lock */
} WorkDeque;

static _Atomic(WorkDeque*) g_deques[MAX_DEQUES];
static _Atomic int32_t g_deques_reserved = 0;

static _Thread_local LyricTask* tl_current = NULL; /* task whose frame is executing on this thread */
static _Thread_local LyricTask* tl_pending = NULL; /* recorded registration awaiting publication */
static _Thread_local int tl_spawn_hint = 0;
static _Thread_local int tl_busy = 0; /* inside run_one: the running task is counted in g_active */
static _Thread_local WorkDeque* tl_deque = NULL;
static _Thread_local int tl_deque_tried = 0;
static _Thread_local uint32_t tl_pops = 0;
static _Thread_local uint32_t tl_rng = 0;
static _Thread_local uint32_t tl_io_tick = 0;

static inline int mt(void) {
    return atomic_load_explicit(&g_mt, memory_order_acquire);
}

static inline int32_t state_of(LyricTask* t) {
    return atomic_load_explicit(&t->state, memory_order_acquire);
}

static inline void set_state(LyricTask* t, int32_t s) {
    atomic_store_explicit(&t->state, s, memory_order_release);
}

static void* async_worker_main(void* arg);

/* LYRIC_ASYNC_THREADS: an integer >= 1 (1 selects the cooperative scheduler);
 * unset or anything else is the processor count (D404: the compiler checks
 * what crosses a spawn, so tasks may run in parallel by default). */
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
    int n = lyric_processor_count();
    return n > MAX_ASYNC_THREADS ? MAX_ASYNC_THREADS : n;
#endif
}

/* ── The poll system call and the wake pipe ─────────────────────────── */

#if defined(__wasi__)
typedef struct io_pollfd {
    int fd;
    short events;
    short revents;
} io_pollfd;
#define IO_POLLIN 1
#define IO_POLLOUT 4
#define IO_POLLERR 8
static int io_sys_poll(io_pollfd* fds, int n, int timeout_ms) {
    (void)fds;
    (void)n;
    (void)timeout_ms;
    return 0;
}
static void io_set_fd(io_pollfd* p, int64_t fd) {
    p->fd = (int)fd;
}
static void io_wake_init(void) {
}
static void io_wake(void) {
}
static void io_wake_drain(void) {
}
static int64_t io_wake_fd(void) {
    return -1;
}
#elif defined(_WIN32)
typedef WSAPOLLFD io_pollfd;
#define IO_POLLIN POLLRDNORM
#define IO_POLLOUT POLLWRNORM
#define IO_POLLERR (POLLERR | POLLHUP | POLLNVAL)
static int32_t g_wake_r = -1;
static int32_t g_wake_w = -1;
static int io_sys_poll(io_pollfd* fds, int n, int timeout_ms) {
    return WSAPoll(fds, (ULONG)n, timeout_ms);
}
static void io_set_fd(io_pollfd* p, int64_t fd) {
    p->fd = (SOCKET)(intptr_t)fd;
}
static void io_wake_init(void) {
    if (lyric_sock_wake_pipe_new(&g_wake_r, &g_wake_w) != 0) {
        lyric_panic_msg("the async I/O reactor could not create its wake socket pair", "lyric_async.c", __LINE__);
    }
    u_long on = 1;
    (void)ioctlsocket((SOCKET)(intptr_t)g_wake_r, FIONBIO, &on);
}
static void io_wake(void) {
    (void)lyric_sock_wake_pipe_signal(g_wake_w);
}
static void io_wake_drain(void) {
    char buf[64];
    while (recv((SOCKET)(intptr_t)g_wake_r, buf, (int)sizeof buf, 0) > 0) {
    }
}
static int64_t io_wake_fd(void) {
    return g_wake_r;
}
#else
typedef struct pollfd io_pollfd;
#define IO_POLLIN POLLIN
#define IO_POLLOUT POLLOUT
#define IO_POLLERR (POLLERR | POLLHUP | POLLNVAL)
static int g_wake_r = -1;
static int g_wake_w = -1;
static int io_sys_poll(io_pollfd* fds, int n, int timeout_ms) {
    int rc;
    do {
        rc = poll(fds, (nfds_t)n, timeout_ms);
    } while (rc < 0 && errno == EINTR && timeout_ms < 0);
    return rc;
}
static void io_set_fd(io_pollfd* p, int64_t fd) {
    p->fd = (int)fd;
}
static void io_wake_init(void) {
    int fds[2];
    if (pipe(fds) != 0) {
        lyric_panic_msg("the async I/O reactor could not create its wake pipe", "lyric_async.c", __LINE__);
    }
    for (int i = 0; i < 2; i++) {
        (void)fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
        (void)fcntl(fds[i], F_SETFD, FD_CLOEXEC);
    }
    g_wake_r = fds[0];
    g_wake_w = fds[1];
}
static void io_wake(void) {
    char b = 1;
    ssize_t w;
    do {
        w = write(g_wake_w, &b, 1);
    } while (w < 0 && errno == EINTR); /* EAGAIN: a wake byte is already pending */
}
static void io_wake_drain(void) {
    char buf[64];
    while (read(g_wake_r, buf, sizeof buf) > 0) {
    }
}
static int64_t io_wake_fd(void) {
    return g_wake_r;
}
#endif

static int io_events_to_poll(int32_t events) {
    int e = 0;
    if (events & LYRIC_IO_READ) {
        e |= IO_POLLIN;
    }
    if (events & LYRIC_IO_WRITE) {
        e |= IO_POLLOUT;
    }
    return e;
}

static int32_t io_poll_to_result(int revents) {
    int32_t r = 0;
    if (revents & IO_POLLIN) {
        r |= LYRIC_IO_READ;
    }
    if (revents & IO_POLLOUT) {
        r |= LYRIC_IO_WRITE;
    }
    if (revents & IO_POLLERR) {
        r |= LYRIC_IO_ERROR;
    }
    return r;
}

#if !defined(__wasi__)
/* The monotonic deadline `ms` milliseconds after `now`, saturating at INT64_MAX.
 * Only the descriptor waits use it, and wasm32 has none. */
static int64_t deadline_after_ms(int64_t now, int64_t ms) {
    return ms > (INT64_MAX - now) / 1000000 ? INT64_MAX : now + ms * 1000000;
}
#endif

/* Milliseconds for poll from nanoseconds (-1: forever), rounded up so a poll
 * never returns just before the deadline it waits for. */
static int io_timeout_ms(int64_t ns) {
    if (ns < 0) {
        return -1;
    }
    int64_t ms = (ns + 999999) / 1000000;
    return ms > 2147483647 ? 2147483647 : (int)ms;
}

static void sched_init(void) {
    int n = detect_async_threads();
    if (n >= 2) {
        g_mu = lyric_alloc((uint64_t)lyric_mutex_size());
        lyric_mutex_init(g_mu);
        g_cv = lyric_alloc((uint64_t)lyric_cond_size());
        lyric_cond_init(g_cv);
        io_wake_init();
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
    atomic_store_explicit(&t->waiters, (LyricTask*)NULL, memory_order_relaxed);
    t->next = NULL;
    t->park_kind = PARK_NONE;
    t->park_dep = NULL;
    t->counted = 0;
    atomic_store_explicit(&t->joined, 0, memory_order_relaxed);
    t->io_fd = -1;
    t->io_events = 0;
    t->io_fd2 = -1;
    t->io_events2 = 0;
    t->io_result = 0;
    return t;
}

/* ── Idle parking and the active count (multi-threaded mode) ─────────── */

/* A thread searching for work will find a task just made ready without being
 * signalled (it re-checks every deque before it parks, rule 6), so a parked one
 * is woken only when nobody is searching. */
/* An idle thread is either waiting on g_cv or blocked in the reactor's poll;
 * a parked one is woken by the condition variable when there is one, else the
 * poller by the wake pipe. */
static inline void wake_one_idle(void) {
    if (atomic_load_explicit(&g_searching, memory_order_seq_cst) == 0 &&
        atomic_load_explicit(&g_idle, memory_order_seq_cst) > 0) {
        lyric_mutex_lock(g_mu);
        if (g_cond_waiters > 0) {
            lyric_cond_signal(g_cv);
        } else if (g_polling) {
            io_wake();
        }
        lyric_mutex_unlock(g_mu);
    }
}

static inline void wake_all_idle(void) {
    if (atomic_load_explicit(&g_idle, memory_order_seq_cst) > 0) {
        lyric_mutex_lock(g_mu);
        if (g_polling) {
            io_wake();
        }
        lyric_cond_broadcast(g_cv);
        lyric_mutex_unlock(g_mu);
    }
}

static inline void active_add(int64_t n) {
    atomic_fetch_add_explicit(&g_active, n, memory_order_seq_cst);
}

/* Removes one; the thread that reaches zero wakes the idle threads so a
 * block_on caller re-checks for a deadlock (rule 5). */
static inline void active_sub1(void) {
    if (atomic_fetch_sub_explicit(&g_active, 1, memory_order_seq_cst) == 1) {
        wake_all_idle();
    }
}

/* A task leaving the ready-or-running set (it parks or completes): drops its
 * count when it had one.  The flag is only ever touched by the thread that
 * owns the task at that moment. */
static inline void uncount(LyricTask* t, int was_counted) {
    if (was_counted) {
        active_sub1();
    }
    (void)t;
}

/* A task entering the ready set from a state that was not counted. */
static inline void count_ready(LyricTask* t) {
    if (!t->counted) {
        t->counted = 1;
        active_add(1);
    }
}

/* ── Work deques (multi-threaded mode) ───────────────────────────────── */

/* This thread's deque, created on first use; NULL when MAX_DEQUES threads
 * already have one. */
static WorkDeque* my_deque(void) {
    if (tl_deque || tl_deque_tried) {
        return tl_deque;
    }
    tl_deque_tried = 1;
    int32_t idx = atomic_fetch_add_explicit(&g_deques_reserved, 1, memory_order_relaxed);
    if (idx >= MAX_DEQUES) {
        return NULL;
    }
    WorkDeque* d = (WorkDeque*)lyric_alloc(sizeof(WorkDeque));
    d->mu = lyric_alloc((uint64_t)lyric_mutex_size());
    lyric_mutex_init(d->mu);
    d->buf = (LyricTask**)lyric_alloc((uint64_t)(DEQUE_INITIAL_CAP * sizeof(LyricTask*)));
    d->cap = DEQUE_INITIAL_CAP;
    d->head = 0;
    d->tail = 0;
    atomic_store_explicit(&d->n, 0, memory_order_relaxed);
    atomic_store_explicit(&g_deques[idx], d, memory_order_release);
    tl_deque = d;
    tl_rng = (uint32_t)idx * 2654435761u + 1u;
    return d;
}

static void deque_grow(WorkDeque* d) {
    int64_t ncap = d->cap * 2;
    LyricTask** nb = (LyricTask**)lyric_alloc((uint64_t)ncap * sizeof(LyricTask*));
    int64_t count = d->tail - d->head;
    for (int64_t i = 0; i < count; i++) {
        nb[i] = d->buf[(d->head + i) & (d->cap - 1)];
    }
    lyric_free(d->buf);
    d->buf = nb;
    d->cap = ncap;
    d->head = 0;
    d->tail = count;
}

static void deque_push(WorkDeque* d, LyricTask* t) {
    lyric_mutex_lock(d->mu);
    if (d->tail - d->head == d->cap) {
        deque_grow(d);
    }
    d->buf[d->tail & (d->cap - 1)] = t;
    d->tail++;
    atomic_store_explicit(&d->n, d->tail - d->head, memory_order_seq_cst);
    lyric_mutex_unlock(d->mu);
}

/* Pops the newest task (`oldest` == 0) or the oldest one. */
static LyricTask* deque_pop(WorkDeque* d, int oldest) {
    if (atomic_load_explicit(&d->n, memory_order_relaxed) == 0) {
        return NULL;
    }
    LyricTask* t = NULL;
    lyric_mutex_lock(d->mu);
    if (d->tail != d->head) {
        if (oldest) {
            t = d->buf[d->head & (d->cap - 1)];
            d->head++;
        } else {
            d->tail--;
            t = d->buf[d->tail & (d->cap - 1)];
        }
        atomic_store_explicit(&d->n, d->tail - d->head, memory_order_seq_cst);
    }
    lyric_mutex_unlock(d->mu);
    return t;
}

static int any_deque_nonempty(void) {
    int32_t n = atomic_load_explicit(&g_deques_reserved, memory_order_relaxed);
    if (n > MAX_DEQUES) {
        n = MAX_DEQUES;
    }
    for (int32_t i = 0; i < n; i++) {
        WorkDeque* d = atomic_load_explicit(&g_deques[i], memory_order_acquire);
        if (d && atomic_load_explicit(&d->n, memory_order_seq_cst) > 0) {
            return 1;
        }
    }
    return 0;
}

/* Takes the oldest task of some other thread's deque, starting at a
 * pseudo-random victim so thieves spread out. */
static LyricTask* steal(WorkDeque* mine) {
    int32_t n = atomic_load_explicit(&g_deques_reserved, memory_order_relaxed);
    if (n > MAX_DEQUES) {
        n = MAX_DEQUES;
    }
    if (n == 0) {
        return NULL;
    }
    tl_rng ^= tl_rng << 13;
    tl_rng ^= tl_rng >> 17;
    tl_rng ^= tl_rng << 5;
    int32_t start = (int32_t)(tl_rng % (uint32_t)n);
    for (int32_t k = 0; k < n; k++) {
        WorkDeque* d = atomic_load_explicit(&g_deques[(start + k) % n], memory_order_acquire);
        if (!d || d == mine) {
            continue;
        }
        LyricTask* t = deque_pop(d, 1);
        if (t) {
            return t;
        }
    }
    return NULL;
}

/* ── The shared FIFO (ready queue, or injection queue under g_mu) ────── */

static void fifo_push(LyricTask* t) {
    t->next = NULL;
    if (g_ready_tail) {
        g_ready_tail->next = t;
    } else {
        g_ready_head = t;
    }
    g_ready_tail = t;
}

static LyricTask* fifo_pop(void) {
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

static LyricTask* inject_pop(void) {
    if (atomic_load_explicit(&g_inject_n, memory_order_relaxed) == 0) {
        return NULL;
    }
    lyric_mutex_lock(g_mu);
    LyricTask* t = fifo_pop();
    if (t) {
        atomic_fetch_sub_explicit(&g_inject_n, 1, memory_order_seq_cst);
    }
    lyric_mutex_unlock(g_mu);
    return t;
}

/* Makes `t` READY.  Does not change g_active: a caller moving a task from
 * WAITING or SLEEPING has already added it, a caller moving it from RUNNING
 * keeps the count it had. */
static void ready_push(LyricTask* t) {
    set_state(t, LYRIC_TASK_READY);
    if (!mt()) {
        fifo_push(t);
        return;
    }
    WorkDeque* d = my_deque();
    if (d) {
        deque_push(d, t);
    } else {
        lyric_mutex_lock(g_mu);
        fifo_push(t);
        atomic_fetch_add_explicit(&g_inject_n, 1, memory_order_seq_cst);
        lyric_mutex_unlock(g_mu);
    }
    wake_one_idle();
}

/* The next task this thread should run, flipped to RUNNING, or NULL. */
static LyricTask* take_task(void) {
    LyricTask* t = NULL;
    if (!mt()) {
        t = fifo_pop();
    } else {
        WorkDeque* d = my_deque();
        int fair = ++tl_pops >= FAIR_INTERVAL;
        if (fair) {
            tl_pops = 0;
            t = inject_pop();
        }
        if (!t && d) {
            t = deque_pop(d, fair);
        }
        if (!t) {
            t = inject_pop();
        }
        if (!t) {
            t = steal(d);
        }
    }
    if (t) {
        set_state(t, LYRIC_TASK_RUNNING);
    }
    return t;
}

/* ── Waiter stacks ───────────────────────────────────────────────────── */

/* Pushes `waiter` (already WAITING) on dep's stack; returns 0 when dep has
 * completed and closed it. */
static int waiters_push(LyricTask* dep, LyricTask* waiter) {
    LyricTask* old = atomic_load_explicit(&dep->waiters, memory_order_acquire);
    for (;;) {
        if (old == WAITERS_CLOSED) {
            return 0;
        }
        waiter->next = old;
        if (atomic_compare_exchange_weak_explicit(&dep->waiters, &old, waiter, memory_order_acq_rel,
                                                  memory_order_acquire)) {
            return 1;
        }
    }
}

/* Closes t's waiter stack and makes every waiter READY, in registration
 * order (#5082).  Each waiter keeps the sched ref it took when it parked. */
static void wake_waiters(LyricTask* t) {
    LyricTask* w = atomic_exchange_explicit(&t->waiters, WAITERS_CLOSED, memory_order_acq_rel);
    if (w == WAITERS_CLOSED) {
        lyric_panic_msg("waiters woken twice (scheduler bug)", "lyric_async.c", __LINE__);
    }
    LyricTask* fifo = NULL;
    int64_t count = 0;
    while (w) {
        LyricTask* next = w->next;
        w->next = fifo;
        fifo = w;
        w = next;
        count++;
    }
    if (count == 0) {
        return;
    }
    if (mt()) {
        active_add(count);
    }
    while (fifo) {
        LyricTask* next = fifo->next;
        fifo->counted = 1;
        ready_push(fifo);
        fifo = next;
    }
}

/* ── Sleepers (g_mu held in multi-threaded mode) ─────────────────────── */

/* Deadline-ascending insertion into the sleeper list; returns 1 when `t` is
 * now the earliest sleeper. */
static int sleepers_insert(LyricTask* t) {
    set_state(t, LYRIC_TASK_SLEEPING);
    LyricTask** slot = &g_sleepers;
    while (*slot && (*slot)->wake_deadline_ns <= t->wake_deadline_ns) {
        slot = &(*slot)->next;
    }
    t->next = *slot;
    *slot = t;
    return slot == &g_sleepers;
}

/* Move every sleeper whose deadline has passed to a ready queue; returns the
 * earliest still-pending deadline, or -1 if none. */
static int64_t wake_expired_sleepers(void) {
    int64_t now = lyric_monotonic_nanos();
    while (g_sleepers && g_sleepers->wake_deadline_ns <= now) {
        LyricTask* t = g_sleepers;
        g_sleepers = t->next;
        if (mt()) {
            active_add(1);
            t->counted = 1;
        }
        ready_push(t); /* keeps the sched ref it acquired at SLEEPING */
    }
    return g_sleepers ? g_sleepers->wake_deadline_ns : -1;
}

/* ── The reactor (g_mu held in multi-threaded mode) ──────────────────── */

/* Parks `t` (its io_* fields and wake_deadline_ns set) on the reactor. */
static void io_register(LyricTask* t) {
    set_state(t, LYRIC_TASK_WAITING);
    t->io_result = -1;
    t->next = g_io_head;
    g_io_head = t;
    atomic_fetch_add_explicit(&g_io_count, 1, memory_order_seq_cst);
    if (mt()) {
        if (g_polling) {
            io_wake(); /* the poller must add this descriptor */
        } else if (g_cond_waiters > 0) {
            lyric_cond_signal(g_cv); /* a parked thread becomes the poller */
        }
    }
}

static io_pollfd* g_io_fds = NULL;
static LyricTask** g_io_tasks = NULL; /* the task each entry of g_io_fds belongs to */
static int32_t* g_io_shift = NULL;    /* 0 for its first descriptor, LYRIC_IO_SECOND_SHIFT for its second */
static int64_t g_io_cap = 0;

/* Polls every parked descriptor (and, multi-threaded, the wake pipe) for up to
 * `timeout_ns` (-1: until something happens; capped by the earliest reactor
 * deadline), then makes every ready or timed-out waiter READY.  Multi-threaded,
 * the caller holds g_mu and no other thread is polling; the lock is released
 * around the system call. */
static void io_poll(int64_t timeout_ns) {
    int64_t n = 2 * atomic_load_explicit(&g_io_count, memory_order_relaxed);
    if (n + 1 > g_io_cap) {
        int64_t cap = g_io_cap ? g_io_cap : 64;
        while (cap < n + 1) {
            cap *= 2;
        }
        if (g_io_fds) {
            lyric_free(g_io_fds);
            lyric_free(g_io_tasks);
            lyric_free(g_io_shift);
        }
        g_io_fds = (io_pollfd*)lyric_alloc((uint64_t)cap * sizeof(io_pollfd));
        g_io_tasks = (LyricTask**)lyric_alloc((uint64_t)cap * sizeof(LyricTask*));
        g_io_shift = (int32_t*)lyric_alloc((uint64_t)cap * sizeof(int32_t));
        g_io_cap = cap;
    }
    int64_t now = lyric_monotonic_nanos();
    int64_t k = 0;
    for (LyricTask* t = g_io_head; t; t = t->next) {
        io_set_fd(&g_io_fds[k], t->io_fd);
        g_io_fds[k].events = (short)io_events_to_poll(t->io_events);
        g_io_fds[k].revents = 0;
        g_io_tasks[k] = t;
        g_io_shift[k] = 0;
        k++;
        if (t->io_fd2 >= 0) {
            io_set_fd(&g_io_fds[k], t->io_fd2);
            g_io_fds[k].events = (short)io_events_to_poll(t->io_events2);
            g_io_fds[k].revents = 0;
            g_io_tasks[k] = t;
            g_io_shift[k] = LYRIC_IO_SECOND_SHIFT;
            k++;
        }
        if (t->wake_deadline_ns != INT64_MAX) {
            int64_t left = t->wake_deadline_ns - now;
            if (left < 0) {
                left = 0;
            }
            if (timeout_ns < 0 || left < timeout_ns) {
                timeout_ns = left;
            }
        }
    }
    int64_t nfds = k;
    if (mt()) {
        io_set_fd(&g_io_fds[nfds], io_wake_fd());
        g_io_fds[nfds].events = IO_POLLIN;
        g_io_fds[nfds].revents = 0;
        nfds++;
        g_polling = 1;
        lyric_mutex_unlock(g_mu);
    }
    int rc = io_sys_poll(g_io_fds, (int)nfds, io_timeout_ms(timeout_ns));
    if (mt()) {
        lyric_mutex_lock(g_mu);
        g_polling = 0;
        if (g_io_fds[nfds - 1].revents) {
            io_wake_drain();
        }
    }
    if (rc > 0) {
        for (int64_t i = 0; i < k; i++) {
            if (g_io_fds[i].revents) {
                LyricTask* t = g_io_tasks[i];
                int32_t bits = io_poll_to_result(g_io_fds[i].revents) << g_io_shift[i];
                t->io_result = (t->io_result < 0 ? 0 : t->io_result) | bits;
            }
        }
    }
    /* Only the poller removes waiters, so every snapshotted task is still
     * parked; registrations made during the poll are at the head. */
    now = lyric_monotonic_nanos();
    LyricTask** slot = &g_io_head;
    while (*slot) {
        LyricTask* t = *slot;
        int done = t->io_result >= 0;
        if (!done && t->wake_deadline_ns <= now) {
            t->io_result = 0;
            done = 1;
        }
        if (done) {
            *slot = t->next;
            atomic_fetch_sub_explicit(&g_io_count, 1, memory_order_seq_cst);
            if (mt()) {
                active_add(1);
                t->counted = 1;
            }
            ready_push(t); /* keeps the sched ref it took when it parked */
        } else {
            slot = &t->next;
        }
    }
}

/* ── Task lifecycle ──────────────────────────────────────────────────── */

/* Publish the registration the running coroutine recorded, now that its
 * function has returned and the frame is fully suspended (rule 3).  Ends the
 * task's stretch. */
static void settle_pending(void) {
    LyricTask* t = tl_pending;
    if (!t) {
        return;
    }
    tl_pending = NULL;
    int32_t kind = t->park_kind;
    LyricTask* dep = t->park_dep;
    t->park_kind = PARK_NONE;
    t->park_dep = NULL;
    /* Read and clear the count before the task becomes visible to a waker,
     * which sets it again when it makes the task ready. */
    int was_counted = t->counted;
    t->counted = 0;
    switch (kind) {
    case PARK_AWAIT:
        set_state(t, LYRIC_TASK_WAITING);
        if (waiters_push(dep, t)) {
            uncount(t, was_counted);
        } else {
            t->counted = was_counted;
            count_ready(t);
            ready_push(t); /* the dependency finished while this task was suspending */
        }
        break;
    case PARK_SLEEP:
        lyric_mutex_lock(g_mu);
        if (sleepers_insert(t)) {
            /* A new earliest deadline: re-time the idle waiters and the poller. */
            if (g_polling) {
                io_wake();
            }
            if (atomic_load_explicit(&g_idle, memory_order_seq_cst) > 0) {
                lyric_cond_broadcast(g_cv);
            }
        }
        lyric_mutex_unlock(g_mu);
        uncount(t, was_counted);
        break;
    case PARK_IO:
        lyric_mutex_lock(g_mu);
        io_register(t);
        lyric_mutex_unlock(g_mu);
        uncount(t, was_counted);
        break;
    case PARK_YIELD:
        t->counted = was_counted;
        count_ready(t);
        ready_push(t);
        break;
    default:
        lyric_panic_msg("settle of a task with no recorded registration (scheduler bug)", "lyric_async.c", __LINE__);
    }
}

LyricTask* lyric_task_new(void* coro_handle) {
    sched_ensure();
    LyricTask* t = task_alloc(coro_handle);
    if (mt()) {
        settle_pending();
        /* The ramp stretch is counted unless it runs inside a resumed task,
         * whose own count covers this thread until the ramp returns. */
        if (!tl_busy) {
            t->counted = 1;
            active_add(1);
        }
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
    int32_t st = state_of(t);
    if (st == LYRIC_TASK_COMPLETE) {
        lyric_panic_msg("task completed twice (scheduler bug)", "lyric_async.c", __LINE__);
    }
    /* lyric_task_complete only ever runs inside a coroutine body, which
     * only executes while its task is RUNNING (the ramp, or a resume
     * that take_task already flipped to RUNNING) or re-registers itself
     * (SLEEPING/WAITING) before returning — READY means "queued, not yet
     * resumed," which is not a state a running body can observe itself
     * in, so it is deliberately excluded here. */
    int had_sched_ref = st == LYRIC_TASK_SLEEPING || st == LYRIC_TASK_WAITING;
    t->result = result;
    t->result_is_ref = result_is_ref;
    int was_counted = t->counted;
    t->counted = 0;
    atomic_store_explicit(&t->state, LYRIC_TASK_COMPLETE, memory_order_seq_cst);
    wake_waiters(t);
    if (mt()) {
        if (atomic_load_explicit(&t->joined, memory_order_seq_cst)) {
            wake_all_idle(); /* a block_on caller is waiting for exactly this task */
        }
        uncount(t, was_counted);
    }
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
    atomic_fetch_add_explicit(&g_host_pending, 1, memory_order_seq_cst);
    return t;
}

/* Complete a pending host task and wake what awaits it. */
static void host_task_settle(LyricTask* t, int64_t result, int32_t result_is_ref) {
    int32_t expected = LYRIC_TASK_HOST;
    t->result = result;
    t->result_is_ref = result_is_ref;
    if (!atomic_compare_exchange_strong_explicit(&t->state, &expected, LYRIC_TASK_COMPLETE, memory_order_seq_cst,
                                                 memory_order_seq_cst)) {
        lyric_panic_msg("host task finished twice, or is not a host task", "lyric_async.c", __LINE__);
    }
    atomic_fetch_sub_explicit(&g_host_pending, 1, memory_order_seq_cst);
    wake_waiters(t); /* the waiters keep the sched ref they took when they parked */
    if (mt()) {
        wake_all_idle();
    }
    lyric_release(t); /* the host's ref */
}

void lyric_host_task_finish(LyricTask* t, int64_t result, int32_t result_is_ref) {
    host_task_settle(t, result, result_is_ref);
}

void lyric_host_task_fail(LyricTask* t, LyricString* message) {
    host_task_settle(t, (int64_t)(intptr_t)message, 3);
}

int64_t lyric_host_tasks_pending(void) {
    return atomic_load_explicit(&g_host_pending, memory_order_seq_cst);
}

/* ── Registration (called by the running coroutine, then it suspends) ── */

/* Register the currently-RUNNING task as awaiting `dep`; the caller
 * must suspend immediately after.  Single-threaded: panics if dep is
 * already complete (codegen checks is_complete first and skips the
 * suspend).  Multi-threaded: dep can complete between that check and the
 * suspend, so the registration is only recorded here and published after
 * the coroutine returns, where a finished dep sends the waiter straight
 * back to a ready queue. */
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
    set_state(waiter, LYRIC_TASK_WAITING);
    if (!waiters_push(dep, waiter)) {
        lyric_panic_msg("await registration on a complete task (codegen bug)", "lyric_async.c", __LINE__);
    }
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

/* Register the currently-RUNNING task as waiting until `fd` is ready for
 * `events` or `timeout_ms` passes (negative: no timeout); the caller must
 * suspend immediately after and read lyric_async_wait_fd_result on resume. */
void lyric_async_wait_fd(LyricTask* t, int64_t fd, int32_t events, int64_t timeout_ms) {
    lyric_async_wait_fd2(t, fd, events, -1, 0, timeout_ms);
}

void lyric_async_wait_fd2(LyricTask* t, int64_t fd, int32_t events, int64_t fd2, int32_t events2,
                          int64_t timeout_ms) {
#if defined(__wasi__)
    (void)t;
    (void)fd;
    (void)events;
    (void)fd2;
    (void)events2;
    (void)timeout_ms;
    lyric_panic_msg("waiting on a descriptor is not supported on wasm32", "lyric_async.c", __LINE__);
#else
    if (mt()) {
        settle_pending();
    }
    lyric_retain(t); /* the sched ref, held while parked */
    t->io_fd = fd;
    t->io_events = events;
    t->io_fd2 = fd2;
    t->io_events2 = events2;
    t->io_result = -1;
    if (timeout_ms < 0) {
        t->wake_deadline_ns = INT64_MAX;
    } else {
        int64_t now = lyric_monotonic_nanos();
        t->wake_deadline_ns = deadline_after_ms(now, timeout_ms);
    }
    if (mt()) {
        t->park_kind = PARK_IO;
        tl_pending = t;
        return;
    }
    io_register(t);
#endif
}

int32_t lyric_async_wait_fd_result(LyricTask* t) {
    return t->io_result < 0 ? 0 : t->io_result;
}

int32_t lyric_fd_wait(int64_t fd, int32_t events, int64_t timeout_ms) {
    return lyric_fd_wait2(fd, events, -1, 0, timeout_ms);
}

int32_t lyric_fd_wait2(int64_t fd, int32_t events, int64_t fd2, int32_t events2, int64_t timeout_ms) {
#if defined(__wasi__)
    (void)fd;
    (void)events;
    (void)fd2;
    (void)events2;
    (void)timeout_ms;
    lyric_panic_msg("waiting on a descriptor is not supported on wasm32", "lyric_async.c", __LINE__);
    return 0;
#else
    io_pollfd p[2];
    io_set_fd(&p[0], fd);
    p[0].events = (short)io_events_to_poll(events);
    p[0].revents = 0;
    int nfds = 1;
    if (fd2 >= 0) {
        io_set_fd(&p[1], fd2);
        p[1].events = (short)io_events_to_poll(events2);
        p[1].revents = 0;
        nfds = 2;
    }
    int64_t deadline = timeout_ms < 0 ? -1 : deadline_after_ms(lyric_monotonic_nanos(), timeout_ms);
    for (;;) {
        int64_t left = deadline < 0 ? -1 : deadline - lyric_monotonic_nanos();
        if (deadline >= 0 && left < 0) {
            left = 0;
        }
        int rc = io_sys_poll(p, nfds, io_timeout_ms(left));
        if (rc > 0) {
            int32_t r = io_poll_to_result(p[0].revents);
            if (nfds == 2) {
                r |= io_poll_to_result(p[1].revents) << LYRIC_IO_SECOND_SHIFT;
            }
            return r;
        }
        if (rc == 0) {
            return 0;
        }
        /* An interrupted timed poll: go round with the time that is left. */
        if (deadline >= 0 && lyric_monotonic_nanos() >= deadline) {
            return 0;
        }
    }
#endif
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
    WorkDeque* d = my_deque();
    if (d && atomic_load_explicit(&d->n, memory_order_relaxed) >= SPAWN_HOT_QUEUE &&
        atomic_load_explicit(&g_idle, memory_order_relaxed) == 0 &&
        atomic_load_explicit(&g_searching, memory_order_relaxed) == 0) {
        return 0; /* every thread is busy and this one has work to give away: run it here */
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

/* Resume a task returned by take_task (state RUNNING).  The sched ref is held
 * across the resume and settled afterwards — released here whether the task
 * completed (lyric_task_complete saw RUNNING, no double release) or
 * re-registered (registration took its own fresh ref). */
static void run_one(LyricTask* t) {
    LyricTask* prev = tl_current;
    int prev_busy = tl_busy;
    tl_current = t;
    tl_busy = 1;
    lyric_coro_resume(t->coro_handle);
    tl_busy = prev_busy;
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
    if (atomic_load_explicit(&g_host_pending, memory_order_seq_cst) > 0) {
        lyric_panic_msg(
            "awaiting a host operation inside a synchronous call: the host cannot finish it until this call "
            "returns, so make the caller an async func",
            "lyric_async.c", __LINE__);
    }
    lyric_panic_msg("deadlock: awaited task can never complete (no ready tasks, no timers)", "lyric_async.c",
                    __LINE__);
}

/* While threads stay busy nobody blocks in the reactor, so a thread that has
 * just run a task polls it without waiting every FAIR_INTERVAL tasks. */
static void io_poll_if_due(void) {
    if (++tl_io_tick < FAIR_INTERVAL) {
        return;
    }
    tl_io_tick = 0;
    if (atomic_load_explicit(&g_io_count, memory_order_relaxed) == 0) {
        return;
    }
    if (!mt()) {
        io_poll(0);
        return;
    }
    lyric_mutex_lock(g_mu);
    if (!g_polling && g_io_head) {
        io_poll(0);
    }
    lyric_mutex_unlock(g_mu);
}

/* Multi-threaded drive loop, for the worker threads (root == NULL, never
 * returns) and for lyric_task_block_on (returns once `root` completes). */
static void sched_loop(LyricTask* root) {
    int spins = 0;
    int searching = 0;
    for (;;) {
        if (root && state_of(root) == LYRIC_TASK_COMPLETE) {
            if (searching) {
                atomic_fetch_sub_explicit(&g_searching, 1, memory_order_seq_cst);
            }
            return;
        }
        LyricTask* t = take_task();
        if (t) {
            spins = 0;
            if (searching) {
                /* The last searcher to find work hands the search on, so a burst
                 * of ready tasks still reaches the parked threads. */
                searching = 0;
                if (atomic_fetch_sub_explicit(&g_searching, 1, memory_order_seq_cst) == 1 &&
                    (atomic_load_explicit(&g_inject_n, memory_order_seq_cst) > 0 || any_deque_nonempty())) {
                    wake_one_idle();
                }
            }
            run_one(t);
            io_poll_if_due();
            continue;
        }
        if (spins < IDLE_SPINS) {
            if (!searching) {
                searching = 1;
                atomic_fetch_add_explicit(&g_searching, 1, memory_order_seq_cst);
            }
            spins++;
            lyric_thread_yield();
            continue;
        }
        spins = 0;
        if (searching) {
            /* Stop searching before announcing the idle intent, so a thread that
             * made a task ready meanwhile either saw this one searching (and it
             * looks again below) or sees it idle and signals it. */
            searching = 0;
            atomic_fetch_sub_explicit(&g_searching, 1, memory_order_seq_cst);
        }
        if (root) {
            /* Ask the completer of `root` to wake the idle threads (it reads
             * the flag after publishing COMPLETE, and the check below reads
             * the state after this store). */
            atomic_store_explicit(&root->joined, 1, memory_order_seq_cst);
        }
        lyric_mutex_lock(g_mu);
        int64_t next_deadline = wake_expired_sleepers();
        /* Rule 6: announce the idle intent, then look again. */
        atomic_fetch_add_explicit(&g_idle, 1, memory_order_seq_cst);
        int runnable = (root && state_of(root) == LYRIC_TASK_COMPLETE) ||
                       atomic_load_explicit(&g_inject_n, memory_order_seq_cst) > 0 || any_deque_nonempty();
        if (!runnable) {
            if (root && next_deadline < 0 && atomic_load_explicit(&g_active, memory_order_seq_cst) == 0 &&
                atomic_load_explicit(&g_io_count, memory_order_seq_cst) == 0) {
                atomic_fetch_sub_explicit(&g_idle, 1, memory_order_seq_cst);
                lyric_mutex_unlock(g_mu);
                panic_no_progress();
            }
            int64_t wait_ns = next_deadline >= 0 ? next_deadline - lyric_monotonic_nanos() : -1;
            if (wait_ns < 0 && next_deadline >= 0) {
                wait_ns = 0;
            }
            if (g_io_head && !g_polling) {
                io_poll(wait_ns); /* this thread is the poller until something is ready */
            } else if (next_deadline >= 0) {
                if (wait_ns > 0) {
                    g_cond_waiters++;
                    (void)lyric_cond_timedwait(g_cv, g_mu, wait_ns);
                    g_cond_waiters--;
                }
            } else {
                g_cond_waiters++;
                lyric_cond_wait(g_cv, g_mu);
                g_cond_waiters--;
            }
        }
        atomic_fetch_sub_explicit(&g_idle, 1, memory_order_seq_cst);
        lyric_mutex_unlock(g_mu);
    }
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
        LyricTask* t = take_task();
        if (t) {
            run_one(t);
            io_poll_if_due();
            continue;
        }
        int64_t next_deadline = wake_expired_sleepers();
        if (g_ready_head) {
            continue;
        }
        if (g_io_head) {
            int64_t wait_ns = next_deadline < 0 ? -1 : next_deadline - lyric_monotonic_nanos();
            io_poll(next_deadline >= 0 && wait_ns < 0 ? 0 : wait_ns);
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
        LyricTask* t = take_task();
        if (t) {
            run_one(t);
            continue;
        }
        int64_t next_deadline = wake_expired_sleepers();
        if (g_ready_head) {
            continue;
        }
        if (next_deadline < 0) {
            return lyric_host_tasks_pending() > 0 ? -2 : -1;
        }
        int64_t wait_ns = next_deadline - lyric_monotonic_nanos();
        return wait_ns > 0 ? wait_ns : 0;
    }
}
