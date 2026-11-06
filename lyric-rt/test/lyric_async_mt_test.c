/* lyric_async_mt_test.c - the multi-threaded coroutine scheduler (docs/67 G8, D217).
 *
 * The scheduler resumes LLVM coroutine frames through lyric_coro_resume / lyric_coro_destroy,
 * which the generated IR defines.  Here they are defined over FakeCo handles instead: a
 * step-indexed C state machine that follows the exact protocol the code generator emits
 * (spawn hint, lyric_task_new, lyric_task_defer_start, register then return to suspend,
 * lyric_task_complete, lyric_ramp_done after the ramp).
 *
 * Each FakeCo carries a `busy` flag that is set while some thread is executing the coroutine
 * function and cleared when it returns.  A scheduler that let a second thread resume the frame
 * while the first was still suspending would trip it, as would a destroy of a frame that is
 * still running.  The test is meant to be run under ThreadSanitizer and AddressSanitizer
 * (`make -C lyric-rt test-tsan test-asan-async`).
 *
 * LYRIC_ASYNC_THREADS is set here, before the first scheduler call, so the scheduler starts in
 * its multi-threaded mode. */
#if defined(__APPLE__)
/* A strict _POSIX_C_SOURCE hides sysconf(_SC_NPROCESSORS_ONLN) on macOS. */
#define _DARWIN_C_SOURCE 1
#else
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif
#include "lyric_rt.h"

#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define CHECK(cond)                                                                        \
    do {                                                                                   \
        if (!(cond)) {                                                                     \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);       \
            exit(1);                                                                       \
        }                                                                                  \
    } while (0)

enum { K_LEAF = 0, K_AWAIT_DEP = 1, K_NESTED = 2, K_AWAIT_RACE = 3, K_FIB = 4, K_IO = 5, K_AWAIT_EPHEMERAL = 6 };

typedef struct FakeCo {
    LyricTask* task;
    _Atomic int busy;
    _Atomic int dead;
    int kind;
    int step;
    struct FakeCo* dep;
    int64_t value;
    int sleep_ms;
    int work_us;
    struct FakeCo* kids[2]; /* K_FIB: the two spawned subproblems */
    int io_fd;              /* K_IO: the descriptor to wait on */
    int io_timeout_ms;      /* K_IO: the reactor timeout (negative: none) */
    pthread_t creator;
} FakeCo;

static _Atomic int inflight = 0;
static _Atomic int max_inflight = 0;
static _Atomic int destroyed_count = 0;

static void busy_enter(FakeCo* c) {
    int was = atomic_exchange(&c->busy, 1);
    CHECK(was == 0); /* a frame must never run on two threads at once */
    CHECK(atomic_load(&c->dead) == 0);
}

static void busy_leave(FakeCo* c) {
    atomic_store(&c->busy, 0);
}

/* K_FIB frames come from one pool: a destroyed frame stays allocated so its `dead` flag can be
 * checked, and the pool is freed after the test. */
static FakeCo* fib_pool = NULL;
static _Atomic int fib_next = 0;
static int fib_cap = 0;
static _Atomic int fib_migrated = 0;

static FakeCo* fib_frame(void) {
    int i = atomic_fetch_add(&fib_next, 1);
    CHECK(i < fib_cap);
    return &fib_pool[i];
}

static LyricTask* co_call(struct FakeCo* c, int spawn);
static void co_init(struct FakeCo* c, int kind, struct FakeCo* dep, int64_t value, int sleep_ms, int work_us);

static void spin_us(int us) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    do {
        clock_gettime(CLOCK_MONOTONIC, &t1);
    } while ((t1.tv_sec - t0.tv_sec) * 1000000L + (t1.tv_nsec - t0.tv_nsec) / 1000L < us);
}

static void body(FakeCo* c) {
    switch (c->kind) {
    case K_LEAF:
        if (c->step == 0) {
            int now = atomic_fetch_add(&inflight, 1) + 1;
            int prev = atomic_load(&max_inflight);
            while (now > prev && !atomic_compare_exchange_weak(&max_inflight, &prev, now)) {
            }
            spin_us(c->work_us);
            atomic_fetch_sub(&inflight, 1);
            if (c->sleep_ms > 0) {
                c->step = 1;
                lyric_async_sleep(c->task, c->sleep_ms);
                return;
            }
        }
        lyric_task_complete(c->task, c->value, 0);
        c->step = -1;
        return;
    case K_AWAIT_DEP:
    case K_AWAIT_RACE:
        if (c->step == 0 && !lyric_task_is_complete(c->dep->task)) {
            if (c->kind == K_AWAIT_RACE) {
                /* The dependency may finish right here, between the check and the registration. */
                for (int i = 0; i < 50; i++) {
                    sched_yield();
                }
            }
            c->step = 1;
            lyric_async_await(c->task, c->dep->task);
            return;
        }
        lyric_task_complete(c->task, lyric_task_result(c->dep->task) + 1, 0);
        c->step = -1;
        return;
    case K_AWAIT_EPHEMERAL:
        /* Registers on `dep`, then drops the caller's reference so only the scheduler's
         * `park_dep` retain and `worker_run_task`'s completion retain keep `dep` alive. */
        if (c->step == 0) {
            c->step = 1;
            lyric_async_await(c->task, c->dep->task);
            lyric_release(c->dep->task);
            return;
        }
        lyric_task_complete(c->task, c->value + 1, 0);
        c->step = -1;
        return;
    case K_NESTED:
        /* A synchronous await inside a coroutine body drives the scheduler on this thread. */
        lyric_task_block_on(c->dep->task);
        lyric_task_complete(c->task, lyric_task_result(c->dep->task) + 100, 0);
        c->step = -1;
        return;
    case K_IO:
        /* Wait until the pipe is readable (or the timeout passes), then read what arrived. */
        if (c->step == 0) {
            c->step = 1;
            lyric_async_wait_fd(c->task, c->io_fd, LYRIC_IO_READ, c->io_timeout_ms);
            return;
        }
        {
            int32_t r = lyric_async_wait_fd_result(c->task);
            char b = 0;
            int64_t got = 0;
            if (r & LYRIC_IO_READ) {
                got = read(c->io_fd, &b, 1) == 1 ? (int64_t)b : -1;
            }
            lyric_task_complete(c->task, r == 0 ? -100 : got, 0);
            c->step = -1;
        }
        return;
    case K_FIB:
        /* Recursive fork-join: spawn fib(n-1) and fib(n-2), await both.  Most children are
         * stolen by idle threads from the bottom of their spawner's deque. */
        if (c->step == 0) {
            if (!pthread_equal(c->creator, pthread_self())) {
                atomic_fetch_add(&fib_migrated, 1);
            }
            if (c->value < 2) {
                spin_us(20); /* a little work per leaf, so idle threads always find some to steal */
                lyric_task_complete(c->task, c->value, 0);
                c->step = -1;
                return;
            }
            for (int k = 0; k < 2; k++) {
                FakeCo* kid = fib_frame();
                co_init(kid, K_FIB, NULL, c->value - 1 - k, 0, 0);
                c->kids[k] = kid;
                co_call(kid, 1);
            }
            c->step = 1;
        }
        while (c->step == 1 || c->step == 2) {
            FakeCo* kid = c->kids[c->step - 1];
            if (!lyric_task_is_complete(kid->task)) {
                lyric_async_await(c->task, kid->task);
                return;
            }
            c->step++;
        }
        {
            int64_t sum = lyric_task_result(c->kids[0]->task) + lyric_task_result(c->kids[1]->task);
            lyric_release(c->kids[0]->task);
            lyric_release(c->kids[1]->task);
            lyric_task_complete(c->task, sum, 0);
            c->step = -1;
        }
        return;
    default:
        CHECK(0);
    }
}

void lyric_coro_resume(void* hdl) {
    FakeCo* c = (FakeCo*)hdl;
    busy_enter(c);
    body(c);
    busy_leave(c);
}

void lyric_coro_destroy(void* hdl) {
    FakeCo* c = (FakeCo*)hdl;
    CHECK(atomic_load(&c->busy) == 0); /* freeing a frame that is still running */
    CHECK(atomic_exchange(&c->dead, 1) == 0);
    atomic_fetch_add(&destroyed_count, 1);
}

/* The call sequence the generated code emits around an async call. */
static LyricTask* co_call(FakeCo* c, int spawn) {
    if (spawn) {
        lyric_spawn_hint();
    }
    c->task = lyric_task_new(c);
    busy_enter(c);
    if (lyric_task_defer_start(c->task)) {
        busy_leave(c);
        lyric_ramp_done();
        return c->task;
    }
    body(c);
    busy_leave(c);
    lyric_ramp_done();
    return c->task;
}

static void co_init(FakeCo* c, int kind, FakeCo* dep, int64_t value, int sleep_ms, int work_us) {
    c->task = NULL;
    atomic_store(&c->busy, 0);
    atomic_store(&c->dead, 0);
    c->kind = kind;
    c->step = 0;
    c->dep = dep;
    c->value = value;
    c->sleep_ms = sleep_ms;
    c->work_us = work_us;
    c->kids[0] = NULL;
    c->kids[1] = NULL;
    c->creator = pthread_self();
}

static int64_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* A task's frame is destroyed when its last reference goes, and the scheduler drops its own
 * reference only after the resume that completed the task has returned, which can be a moment
 * after the waiter that saw the completion released the handle. */
static int wait_destroyed(int expected) {
    int64_t deadline = now_ms() + 5000;
    while (atomic_load(&destroyed_count) != expected && now_ms() < deadline) {
        usleep(500);
    }
    return atomic_load(&destroyed_count) == expected;
}

static void reset_counters(void) {
    atomic_store(&inflight, 0);
    atomic_store(&max_inflight, 0);
    atomic_store(&destroyed_count, 0);
}

/* Spawned leaves run in parallel with each other and with the spawner. */
static void test_fan_out(void) {
    enum { N = 64 };
    FakeCo* cos = (FakeCo*)calloc(N, sizeof(FakeCo));
    LyricTask* tasks[N];
    reset_counters();
    int64_t t0 = now_ms();
    for (int i = 0; i < N; i++) {
        co_init(&cos[i], K_LEAF, NULL, i, 2, 2000);
        tasks[i] = co_call(&cos[i], 1);
    }
    int64_t sum = 0;
    for (int i = 0; i < N; i++) {
        lyric_task_block_on(tasks[i]);
        sum += lyric_task_result(tasks[i]);
    }
    int64_t elapsed = now_ms() - t0;
    CHECK(sum == (int64_t)N * (N - 1) / 2);
    if (sysconf(_SC_NPROCESSORS_ONLN) >= 2) {
        CHECK(atomic_load(&max_inflight) >= 2); /* bodies genuinely overlapped */
        /* 64 bodies of 2 ms of CPU each take 128 ms back to back; four threads finish well under. */
        CHECK(elapsed < 128 + 64 * 2);
    }
    for (int i = 0; i < N; i++) {
        lyric_release(tasks[i]);
    }
    CHECK(wait_destroyed(N));
    free(cos);
}

/* Many waiters on one dependency, woken from another thread in registration order. */
static void test_fan_in(void) {
    enum { N = 200 };
    FakeCo leaf;
    FakeCo* ws = (FakeCo*)calloc(N, sizeof(FakeCo));
    LyricTask* wt[N];
    reset_counters();
    co_init(&leaf, K_LEAF, NULL, 41, 20, 0);
    LyricTask* lt = co_call(&leaf, 1);
    for (int i = 0; i < N; i++) {
        co_init(&ws[i], K_AWAIT_DEP, &leaf, 0, 0, 0);
        wt[i] = co_call(&ws[i], 1);
    }
    for (int i = 0; i < N; i++) {
        lyric_task_block_on(wt[i]);
        CHECK(lyric_task_result(wt[i]) == 42);
    }
    for (int i = 0; i < N; i++) {
        lyric_release(wt[i]);
    }
    lyric_release(lt);
    CHECK(wait_destroyed(N + 1));
    free(ws);
}

/* The dependency finishes between the awaiter's is_complete check and its registration. */
static void test_register_race(void) {
    enum { ROUNDS = 1500 };
    /* Every round gets fresh frames: a frame is destroyed a moment after its handle is released,
     * so reusing one address would let the test race with the destroy it is checking. */
    FakeCo* frames = (FakeCo*)calloc(2 * ROUNDS, sizeof(FakeCo));
    reset_counters();
    for (int r = 0; r < ROUNDS; r++) {
        FakeCo* leaf = &frames[2 * r];
        FakeCo* waiter = &frames[2 * r + 1];
        co_init(leaf, K_LEAF, NULL, r, 0, 0);
        co_init(waiter, K_AWAIT_RACE, leaf, 0, 0, 0);
        LyricTask* lt = co_call(leaf, 1);
        LyricTask* wt = co_call(waiter, 1);
        lyric_task_block_on(wt);
        CHECK(lyric_task_result(wt) == r + 1);
        lyric_release(wt);
        lyric_release(lt);
    }
    CHECK(wait_destroyed(2 * ROUNDS));
    free(frames);
}

/* A chain of awaits, each link on whichever thread finished the one before. */
static void test_chain(void) {
    enum { DEPTH = 64 };
    FakeCo cos[DEPTH];
    LyricTask* tasks[DEPTH];
    reset_counters();
    co_init(&cos[0], K_LEAF, NULL, 0, 3, 0);
    tasks[0] = co_call(&cos[0], 1);
    for (int i = 1; i < DEPTH; i++) {
        co_init(&cos[i], K_AWAIT_DEP, &cos[i - 1], 0, 0, 0);
        tasks[i] = co_call(&cos[i], 1);
    }
    lyric_task_block_on(tasks[DEPTH - 1]);
    CHECK(lyric_task_result(tasks[DEPTH - 1]) == DEPTH - 1);
    for (int i = 0; i < DEPTH; i++) {
        lyric_release(tasks[i]);
    }
    CHECK(wait_destroyed(DEPTH));
}

/* A synchronous await inside a coroutine body on a worker thread. */
static void test_nested_block_on(void) {
    enum { N = 16 };
    FakeCo leaves[N], nested[N];
    LyricTask *lt[N], *nt[N];
    reset_counters();
    for (int i = 0; i < N; i++) {
        co_init(&leaves[i], K_LEAF, NULL, i, 5, 500);
        co_init(&nested[i], K_NESTED, &leaves[i], 0, 0, 0);
        lt[i] = co_call(&leaves[i], 1);
        nt[i] = co_call(&nested[i], 1);
    }
    for (int i = 0; i < N; i++) {
        lyric_task_block_on(nt[i]);
        CHECK(lyric_task_result(nt[i]) == i + 100);
        lyric_release(nt[i]);
        lyric_release(lt[i]);
    }
    CHECK(wait_destroyed(2 * N));
}

/* A task that is never spawned stays hot on the caller: no deferral without the hint. */
static void test_hot_without_hint(void) {
    FakeCo c;
    reset_counters();
    co_init(&c, K_LEAF, NULL, 7, 0, 0);
    LyricTask* t = co_call(&c, 0);
    CHECK(lyric_task_is_complete(t)); /* finished inside the ramp */
    CHECK(lyric_task_result(t) == 7);
    lyric_release(t);
    CHECK(wait_destroyed(1));
}

/* Spawned tasks whose handles are dropped still run to completion. */
static void test_dropped_handles(void) {
    enum { N = 32 };
    FakeCo* cos = (FakeCo*)calloc(N, sizeof(FakeCo));
    FakeCo* sentinel = (FakeCo*)calloc(1, sizeof(FakeCo));
    reset_counters();
    for (int i = 0; i < N; i++) {
        co_init(&cos[i], K_LEAF, NULL, i, 1, 100);
        lyric_release(co_call(&cos[i], 1)); /* the scheduler's own ref keeps it alive */
    }
    co_init(sentinel, K_LEAF, NULL, 1, 40, 0);
    LyricTask* st = co_call(sentinel, 1);
    lyric_task_block_on(st);
    lyric_release(st);
    CHECK(wait_destroyed(N + 1));
    free(cos);
    free(sentinel);
}

/* Regression test for `park_dep` and `worker_run_task` reference retention:
 * waiters register on a dependency and immediately release their own reference
 * before suspending, while the dependency finishes concurrently on another worker. */
static void test_ephemeral_dep_and_wake_release(void) {
    enum { N = 64 };
    FakeCo* deps = (FakeCo*)calloc(N, sizeof(FakeCo));
    FakeCo* waiters = (FakeCo*)calloc(N, sizeof(FakeCo));
    LyricTask* wt[N];
    reset_counters();
    for (int i = 0; i < N; i++) {
        co_init(&deps[i], K_LEAF, NULL, i, 1, 50);
        co_call(&deps[i], 1);
        co_init(&waiters[i], K_AWAIT_EPHEMERAL, &deps[i], i, 0, 0);
        wt[i] = co_call(&waiters[i], 1);
    }
    for (int i = 0; i < N; i++) {
        lyric_task_block_on(wt[i]);
        CHECK(lyric_task_result(wt[i]) == i + 1);
        lyric_release(wt[i]);
    }
    CHECK(wait_destroyed(2 * N));
    free(deps);
    free(waiters);
}

/* Fine-grained recursive fork-join: thousands of tasks spawned from every thread, almost all of
 * them taken from the oldest end of another thread's deque (work stealing, #8493). */
static void test_fork_join_steal(void) {
    enum { N = 18, FRAMES = 2 * 4181 * 2 + 16 }; /* fib(18) spawns 2 * fib(19) - 2 tasks */
    atomic_store(&fib_migrated, 0);
    reset_counters();
    int migrated = 0;
    for (int round = 0; round < 3; round++) {
        fib_cap = FRAMES;
        fib_pool = (FakeCo*)calloc(FRAMES, sizeof(FakeCo));
        atomic_store(&fib_next, 0);
        atomic_store(&destroyed_count, 0);
        FakeCo* root = fib_frame();
        co_init(root, K_FIB, NULL, N, 0, 0);
        LyricTask* rt = co_call(root, 1);
        lyric_task_block_on(rt);
        CHECK(lyric_task_result(rt) == 2584);
        lyric_release(rt);
        int frames = atomic_load(&fib_next);
        CHECK(frames == 2 * 4181 - 1);
        CHECK(wait_destroyed(frames));
        free(fib_pool);
        fib_pool = NULL;
    }
    migrated = atomic_load(&fib_migrated);
    if (sysconf(_SC_NPROCESSORS_ONLN) >= 2) {
        CHECK(migrated > 0); /* other threads ran spawned children */
    }
}

/* Tasks parked on descriptors (the I/O reactor, #8494): every one of N pipes is written only
 * after all N tasks have parked, so each task must be woken by readiness, not run past it. */
static void test_io_wake(int spawn) {
    enum { N = 256 };
    FakeCo* cos = (FakeCo*)calloc(N, sizeof(FakeCo));
    int (*pipes)[2] = calloc(N, sizeof *pipes);
    LyricTask* tasks[N];
    reset_counters();
    for (int i = 0; i < N; i++) {
        CHECK(pipe(pipes[i]) == 0);
        co_init(&cos[i], K_IO, NULL, 0, 0, 0);
        cos[i].io_fd = pipes[i][0];
        cos[i].io_timeout_ms = -1;
        tasks[i] = co_call(&cos[i], spawn);
    }
    for (int i = 0; i < N; i++) {
        CHECK(!lyric_task_is_complete(tasks[i])); /* nothing written yet */
    }
    for (int i = 0; i < N; i++) {
        char b = (char)(i % 100);
        CHECK(write(pipes[i][1], &b, 1) == 1);
    }
    for (int i = 0; i < N; i++) {
        lyric_task_block_on(tasks[i]);
        CHECK(lyric_task_result(tasks[i]) == i % 100);
        lyric_release(tasks[i]);
    }
    CHECK(wait_destroyed(N));
    for (int i = 0; i < N; i++) {
        close(pipes[i][0]);
        close(pipes[i][1]);
    }
    free(pipes);
    free(cos);
}

/* A reactor wait with a timeout on a descriptor nobody writes resumes with 0; one that is
 * written first resumes ready, and a sleeper alongside them still wakes on time. */
static void test_io_timeout(void) {
    int quiet[2], loud[2];
    CHECK(pipe(quiet) == 0);
    CHECK(pipe(loud) == 0);
    FakeCo a, b, nap;
    reset_counters();
    co_init(&a, K_IO, NULL, 0, 0, 0);
    a.io_fd = quiet[0];
    a.io_timeout_ms = 15;
    co_init(&b, K_IO, NULL, 0, 0, 0);
    b.io_fd = loud[0];
    b.io_timeout_ms = 5000;
    co_init(&nap, K_LEAF, NULL, 9, 5, 0);
    int64_t t0 = now_ms();
    LyricTask* ta = co_call(&a, 1);
    LyricTask* tb = co_call(&b, 1);
    LyricTask* tn = co_call(&nap, 1);
    char x = 42;
    CHECK(write(loud[1], &x, 1) == 1);
    lyric_task_block_on(tb);
    CHECK(lyric_task_result(tb) == 42);
    lyric_task_block_on(tn);
    CHECK(lyric_task_result(tn) == 9);
    lyric_task_block_on(ta);
    CHECK(lyric_task_result(ta) == -100); /* timed out */
    int64_t elapsed = now_ms() - t0;
    CHECK(elapsed >= 14 && elapsed < 2000);
    lyric_release(ta);
    lyric_release(tb);
    lyric_release(tn);
    CHECK(wait_destroyed(3));
    close(quiet[0]);
    close(quiet[1]);
    close(loud[0]);
    close(loud[1]);
}

/* While every thread is busy with compute-bound tasks, a descriptor that becomes ready is
 * still noticed: busy threads poll the reactor between tasks. */
static void test_io_while_busy(void) {
    enum { WORK = 64 };
    FakeCo* work = (FakeCo*)calloc(WORK, sizeof(FakeCo));
    LyricTask* wt[WORK];
    int p[2];
    CHECK(pipe(p) == 0);
    FakeCo io;
    reset_counters();
    co_init(&io, K_IO, NULL, 0, 0, 0);
    io.io_fd = p[0];
    io.io_timeout_ms = -1;
    LyricTask* it = co_call(&io, 1);
    for (int i = 0; i < WORK; i++) {
        co_init(&work[i], K_LEAF, NULL, 1, 0, 3000);
        wt[i] = co_call(&work[i], 1);
    }
    char x = 7;
    CHECK(write(p[1], &x, 1) == 1);
    lyric_task_block_on(it);
    CHECK(lyric_task_result(it) == 7);
    for (int i = 0; i < WORK; i++) {
        lyric_task_block_on(wt[i]);
        lyric_release(wt[i]);
    }
    lyric_release(it);
    CHECK(wait_destroyed(WORK + 1));
    close(p[0]);
    close(p[1]);
    free(work);
}

/* The blocking form for synchronous callers. */
static void test_fd_wait_sync(void) {
    int p[2];
    CHECK(pipe(p) == 0);
    CHECK(lyric_fd_wait(p[0], LYRIC_IO_READ, 10) == 0);
    CHECK((lyric_fd_wait(p[1], LYRIC_IO_WRITE, 10) & LYRIC_IO_WRITE) != 0);
    char x = 1;
    CHECK(write(p[1], &x, 1) == 1);
    CHECK((lyric_fd_wait(p[0], LYRIC_IO_READ, -1) & LYRIC_IO_READ) != 0);
    CHECK((lyric_fd_wait(p[0], LYRIC_IO_READ, INT64_MAX) & LYRIC_IO_READ) != 0); /* the deadline saturates */
    close(p[0]);
    close(p[1]);
}

int main(void) {
    /* LYRIC_ASYNC_THREADS=1 in the environment runs the reactor tests under the cooperative
     * scheduler instead; the rest need several threads. */
    setenv("LYRIC_ASYNC_THREADS", "4", 0);
    if (lyric_async_threads() == 0) {
        test_fd_wait_sync();
        test_io_wake(0);
        test_io_wake(1);
        test_io_timeout();
        test_io_while_busy();
        printf("lyric_async_mt_test: reactor tests passed (cooperative scheduler)\n");
        return 0;
    }
    test_hot_without_hint();
    test_fan_out();
    test_fan_in();
    test_register_race();
    test_chain();
    test_nested_block_on();
    test_dropped_handles();
    test_ephemeral_dep_and_wake_release();
    test_fork_join_steal();
    test_fd_wait_sync();
    test_io_wake(0);
    test_io_wake(1);
    test_io_timeout();
    test_io_while_busy();
    printf("lyric_async_mt_test: all tests passed\n");
    return 0;
}
