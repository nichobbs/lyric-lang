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
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#include "lyric_rt.h"

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

enum { K_LEAF = 0, K_AWAIT_DEP = 1, K_NESTED = 2, K_AWAIT_RACE = 3 };

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
    case K_NESTED:
        /* A synchronous await inside a coroutine body drives the scheduler on this thread. */
        lyric_task_block_on(c->dep->task);
        lyric_task_complete(c->task, lyric_task_result(c->dep->task) + 100, 0);
        c->step = -1;
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

int main(void) {
    setenv("LYRIC_ASYNC_THREADS", "4", 1);
    CHECK(lyric_async_threads() == 1);
    test_hot_without_hint();
    test_fan_out();
    test_fan_in();
    test_register_race();
    test_chain();
    test_nested_block_on();
    test_dropped_handles();
    printf("lyric_async_mt_test: all tests passed\n");
    return 0;
}
