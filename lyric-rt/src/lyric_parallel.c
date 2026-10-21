/* lyric_parallel.c - a fork-join worker pool for data-parallel loops (docs/67 G8).
 *
 * `lyric_parallel_for(count, body, ud)` runs `body(i, ud)` for every i in [0, count) across the
 * pool's threads and the calling thread, and returns when all have finished.  Indices are
 * claimed one at a time from an atomic counter, so uneven work balances itself.  It is the
 * runtime half of `Std.Parallel`; the library splits a buffer into disjoint chunks and each
 * index is one chunk, which is why the runtime, not user code, owns the disjointness.
 *
 * Design:
 *   - The pool is created on first use with `lyric_parallel_threads() - 1` workers (the caller is
 *     the last thread).  `LYRIC_THREADS` overrides the processor count; 1 means no pool and a
 *     plain serial loop.  Workers are daemon-like: they are never joined and die with the process.
 *   - One job at a time.  A second caller on another thread waits on `submit_mu`, so jobs never
 *     interleave and a caller's stack-allocated job cannot be touched by a later job.
 *   - A body that calls `lyric_parallel_for` again (from a worker or from the caller's share of
 *     the same job) runs the inner loop serially on its own thread, so nesting cannot deadlock.
 *   - A worker holds the job only between taking it (under `mu`, counted in `active`) and
 *     finishing its share (under `mu`); the caller waits for `done == count && active == 0`
 *     before returning, so no worker touches the job after it is gone.
 *   - Happens-before: a worker publishes its writes with the release in the `mu` unlock that
 *     decrements `active`; the caller acquires them when it re-locks `mu` to observe `active == 0`.
 *   - A panic in a body ends the process (no unwinding, D-N-003).
 *
 * wasm32-wasi has no threads: the pool is compiled out and the loop is serial. */
#if defined(__linux__) || defined(__wasi__)
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <stdint.h>
#include <stdlib.h>

#if defined(__wasi__)

int32_t lyric_parallel_threads(void) {
    return 1;
}

void lyric_parallel_for(int64_t count, void (*body)(int64_t, void*), void* ud) {
    for (int64_t i = 0; i < count; i++) {
        body(i, ud);
    }
}

#else

#include <pthread.h>
#include <unistd.h>

typedef struct {
    void (*body)(int64_t, void*);
    void* ud;
    int64_t count;
    _Atomic int64_t next;
    _Atomic int64_t done;
} LyricParallelJob;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t work_cv = PTHREAD_COND_INITIALIZER;
static pthread_cond_t done_cv = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t submit_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t pool_once = PTHREAD_ONCE_INIT;

static LyricParallelJob* current_job = NULL; /* guarded by mu */
static uint64_t generation = 0;              /* guarded by mu: bumped per job */
static int active_workers = 0;               /* guarded by mu */
static int pool_workers = 0;                 /* written once by pool_init */
static int configured_threads = 1;           /* written once by pool_init */

/* Set while this thread is running a body, so a nested call runs serially. */
static _Thread_local int in_body = 0;

static int detect_threads(void) {
    const char* env = getenv("LYRIC_THREADS");
    if (env && *env) {
        char* end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && *end == '\0' && v >= 1) {
            return v > 256 ? 256 : (int)v;
        }
    }
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) {
        n = 1;
    }
    return n > 256 ? 256 : (int)n;
}

static void run_share(LyricParallelJob* job) {
    in_body = 1;
    for (;;) {
        int64_t i = atomic_fetch_add_explicit(&job->next, 1, memory_order_relaxed);
        if (i >= job->count) {
            break;
        }
        job->body(i, job->ud);
        atomic_fetch_add_explicit(&job->done, 1, memory_order_release);
    }
    in_body = 0;
}

static void* worker_main(void* arg) {
    (void)arg;
    uint64_t seen = 0;
    for (;;) {
        pthread_mutex_lock(&mu);
        while (generation == seen || current_job == NULL) {
            if (generation != seen && current_job == NULL) {
                seen = generation; /* the job finished before this worker woke */
            }
            pthread_cond_wait(&work_cv, &mu);
        }
        seen = generation;
        LyricParallelJob* job = current_job;
        active_workers++;
        pthread_mutex_unlock(&mu);

        run_share(job);

        pthread_mutex_lock(&mu);
        active_workers--;
        pthread_cond_broadcast(&done_cv);
        pthread_mutex_unlock(&mu);
    }
    return NULL;
}

static void pool_init(void) {
    configured_threads = detect_threads();
    int want = configured_threads - 1;
    for (int i = 0; i < want; i++) {
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        int rc = pthread_create(&t, &attr, worker_main, NULL);
        pthread_attr_destroy(&attr);
        if (rc != 0) {
            break; /* run with the workers that started; the caller always helps */
        }
        pool_workers++;
    }
}

int32_t lyric_parallel_threads(void) {
    pthread_once(&pool_once, pool_init);
    return pool_workers + 1;
}

void lyric_parallel_for(int64_t count, void (*body)(int64_t, void*), void* ud) {
    if (count <= 0) {
        return;
    }
    pthread_once(&pool_once, pool_init);
    if (count == 1 || pool_workers == 0 || in_body) {
        int saved = in_body;
        in_body = 1;
        for (int64_t i = 0; i < count; i++) {
            body(i, ud);
        }
        in_body = saved;
        return;
    }
    LyricParallelJob job;
    job.body = body;
    job.ud = ud;
    job.count = count;
    atomic_store_explicit(&job.next, 0, memory_order_relaxed);
    atomic_store_explicit(&job.done, 0, memory_order_relaxed);

    pthread_mutex_lock(&submit_mu);
    pthread_mutex_lock(&mu);
    current_job = &job;
    generation++;
    pthread_cond_broadcast(&work_cv);
    pthread_mutex_unlock(&mu);

    run_share(&job);

    pthread_mutex_lock(&mu);
    while (atomic_load_explicit(&job.done, memory_order_acquire) < count || active_workers > 0) {
        pthread_cond_wait(&done_cv, &mu);
    }
    current_job = NULL;
    pthread_mutex_unlock(&mu);
    pthread_mutex_unlock(&submit_mu);
}

#endif
