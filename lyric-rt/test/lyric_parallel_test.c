/* Unit tests for lyric_parallel.c (docs/67 G8).  Run twice by the Makefile: with the default thread
 * count, and with LYRIC_THREADS=1 and the `--serial` argument, which expects no pool. */
#include "lyric_rt.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
static int serial_mode = 0;

#define CHECK(cond, msg)                                           \
    do {                                                           \
        if (!(cond)) {                                             \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); \
            failures++;                                            \
        }                                                          \
    } while (0)

static void mark(int64_t i, void* ud) {
    _Atomic int32_t* slots = (_Atomic int32_t*)ud;
    atomic_fetch_add(&slots[i], 1);
}

static void test_each_index_once(void) {
    enum { N = 100000 };
    _Atomic int32_t* slots = calloc(N, sizeof *slots);
    lyric_parallel_for(N, mark, slots);
    int bad = 0;
    for (int i = 0; i < N; i++) {
        if (atomic_load(&slots[i]) != 1) bad++;
    }
    CHECK(bad == 0, "every index must run exactly once");
    free(slots);
}

static void write_square(int64_t i, void* ud) {
    int64_t* out = (int64_t*)ud;
    out[i] = i * i; /* plain stores to distinct slots: the join must publish them */
}

static void test_results_visible_after_return(void) {
    enum { N = 4096 };
    int64_t* out = calloc(N, sizeof *out);
    for (int round = 0; round < 50; round++) {
        memset(out, 0, N * sizeof *out);
        lyric_parallel_for(N, write_square, out);
        int bad = 0;
        for (int i = 0; i < N; i++) {
            if (out[i] != (int64_t)i * i) bad++;
        }
        CHECK(bad == 0, "writes by workers must be visible to the caller after the loop");
    }
    free(out);
}

static void no_call(int64_t i, void* ud) {
    (void)i;
    (void)ud;
    abort();
}

static void test_empty(void) {
    lyric_parallel_for(0, no_call, NULL);
    lyric_parallel_for(-5, no_call, NULL);
}

typedef struct {
    _Atomic int64_t inner_total;
} NestState;

static void inner_body(int64_t i, void* ud) {
    atomic_fetch_add(&((NestState*)ud)->inner_total, i + 1);
}

static void outer_body(int64_t i, void* ud) {
    (void)i;
    lyric_parallel_for(10, inner_body, ud); /* runs serially on this thread, no deadlock */
}

static void test_nested(void) {
    NestState s;
    atomic_store(&s.inner_total, 0);
    lyric_parallel_for(64, outer_body, &s);
    CHECK(atomic_load(&s.inner_total) == 64 * 55, "nested loops must all run");
}

static void* caller_thread(void* arg) {
    _Atomic int64_t* total = (_Atomic int64_t*)arg;
    for (int r = 0; r < 20; r++) {
        _Atomic int32_t* slots = calloc(500, sizeof *slots);
        lyric_parallel_for(500, mark, slots);
        for (int i = 0; i < 500; i++) {
            if (atomic_load(&slots[i]) == 1) atomic_fetch_add(total, 1);
        }
        free(slots);
    }
    return NULL;
}

static void test_concurrent_callers(void) {
    enum { CALLERS = 4 };
    pthread_t t[CALLERS];
    _Atomic int64_t total;
    atomic_store(&total, 0);
    for (int i = 0; i < CALLERS; i++) pthread_create(&t[i], NULL, caller_thread, &total);
    for (int i = 0; i < CALLERS; i++) pthread_join(t[i], NULL);
    CHECK(atomic_load(&total) == (int64_t)CALLERS * 20 * 500, "loops from several threads must not interleave");
}

static _Atomic int64_t seen_threads_mask;

static void record_thread(int64_t i, void* ud) {
    (void)i;
    (void)ud;
    /* Work long enough that more than one thread gets a share. */
    volatile double x = 0;
    for (int k = 0; k < 20000; k++) x += k * 0.5;
    static _Thread_local int slot = -1;
    static _Atomic int next_slot;
    if (slot < 0) slot = atomic_fetch_add(&next_slot, 1) % 62;
    atomic_fetch_or(&seen_threads_mask, (int64_t)1 << slot);
}

static void test_uses_threads(void) {
    int n = lyric_parallel_threads();
    if (serial_mode) {
        CHECK(n == 1, "LYRIC_THREADS=1 must give one thread");
        return;
    }
    CHECK(n >= 1, "at least the caller");
    if (n == 1) return; /* a single-processor machine */
    atomic_store(&seen_threads_mask, 0);
    lyric_parallel_for(2000, record_thread, NULL);
    int distinct = __builtin_popcountll((unsigned long long)atomic_load(&seen_threads_mask));
    CHECK(distinct >= 2, "a loop over a pool must use more than one thread");
}

int main(int argc, char** argv) {
    serial_mode = argc > 1 && strcmp(argv[1], "--serial") == 0;
    test_each_index_once();
    test_results_visible_after_return();
    test_empty();
    test_nested();
    test_concurrent_callers();
    test_uses_threads();
    if (failures == 0) {
        printf("lyric_parallel tests: ok (%d threads%s)\n", lyric_parallel_threads(), serial_mode ? ", serial" : "");
        return 0;
    }
    return 1;
}
