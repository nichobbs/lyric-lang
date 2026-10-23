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
 * wasm32-wasi has no threads: the pool is compiled out and the loop is serial.  Windows runs the
 * same pool over SRW locks, condition variables and one-time initialisation (docs/67 G9). */
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

/* A call from inside a body (in_body is thread-local) runs serially, so nesting cannot deadlock.
 * A call from a thread that is not a pool worker, such as a user pthread, takes submit_mu and
 * so runs one job at a time with the others. */
void lyric_parallel_for(int64_t count, void (*body)(int64_t, void*), void* ud) {
    for (int64_t i = 0; i < count; i++) {
        body(i, ud);
    }
}

#else

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <process.h>

typedef SRWLOCK pool_mutex_t;
typedef CONDITION_VARIABLE pool_cond_t;
typedef INIT_ONCE pool_once_t;
#define POOL_MUTEX_INIT SRWLOCK_INIT
#define POOL_COND_INIT CONDITION_VARIABLE_INIT
#define POOL_ONCE_INIT INIT_ONCE_STATIC_INIT
#define pool_lock(m) AcquireSRWLockExclusive(m)
#define pool_unlock(m) ReleaseSRWLockExclusive(m)
#define pool_wait(c, m) SleepConditionVariableSRW((c), (m), INFINITE, 0)
#define pool_broadcast(c) WakeAllConditionVariable(c)

static void (*pool_once_fn)(void);

static BOOL CALLBACK pool_once_thunk(PINIT_ONCE once, PVOID param, PVOID* ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    pool_once_fn();
    return TRUE;
}

static void pool_call_once(pool_once_t* once, void (*fn)(void)) {
    pool_once_fn = fn;
    InitOnceExecuteOnce(once, pool_once_thunk, NULL, NULL);
}

static unsigned __stdcall pool_thread_entry(void* arg);

/* Starts a worker nobody joins; 0 on success. */
static int pool_spawn_detached(void) {
    uintptr_t h = _beginthreadex(NULL, 0, pool_thread_entry, NULL, 0, NULL);
    if (h == 0) return -1;
    CloseHandle((HANDLE)h);
    return 0;
}

static long online_processors(void) {
    return (long)GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
}
#else
#include <pthread.h>
#include <unistd.h>

typedef pthread_mutex_t pool_mutex_t;
typedef pthread_cond_t pool_cond_t;
typedef pthread_once_t pool_once_t;
#define POOL_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#define POOL_COND_INIT PTHREAD_COND_INITIALIZER
#define POOL_ONCE_INIT PTHREAD_ONCE_INIT
#define pool_lock(m) pthread_mutex_lock(m)
#define pool_unlock(m) pthread_mutex_unlock(m)
#define pool_wait(c, m) pthread_cond_wait((c), (m))
#define pool_broadcast(c) pthread_cond_broadcast(c)

static void pool_call_once(pool_once_t* once, void (*fn)(void)) {
    pthread_once(once, fn);
}

static void* worker_main(void* arg);

static int pool_spawn_detached(void) {
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&t, &attr, worker_main, NULL);
    pthread_attr_destroy(&attr);
    return rc == 0 ? 0 : -1;
}

static long online_processors(void) {
    return sysconf(_SC_NPROCESSORS_ONLN);
}
#endif

typedef struct {
    void (*body)(int64_t, void*);
    void* ud;
    int64_t count;
    _Atomic int64_t next;
    _Atomic int64_t done;
} LyricParallelJob;

static pool_mutex_t mu = POOL_MUTEX_INIT;
static pool_cond_t work_cv = POOL_COND_INIT;
static pool_cond_t done_cv = POOL_COND_INIT;
static pool_mutex_t submit_mu = POOL_MUTEX_INIT;
static pool_once_t pool_once = POOL_ONCE_INIT;

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
    long n = online_processors();
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
        pool_lock(&mu);
        while (generation == seen || current_job == NULL) {
            if (generation != seen && current_job == NULL) {
                seen = generation; /* the job finished before this worker woke */
            }
            pool_wait(&work_cv, &mu);
        }
        seen = generation;
        LyricParallelJob* job = current_job;
        active_workers++;
        pool_unlock(&mu);

        run_share(job);

        pool_lock(&mu);
        active_workers--;
        pool_broadcast(&done_cv);
        pool_unlock(&mu);
    }
    return NULL;
}

#if defined(_WIN32)
static unsigned __stdcall pool_thread_entry(void* arg) {
    worker_main(arg);
    return 0;
}
#endif

static void pool_init(void) {
    configured_threads = detect_threads();
    int want = configured_threads - 1;
    for (int i = 0; i < want; i++) {
        if (pool_spawn_detached() != 0) {
            break; /* run with the workers that started; the caller always helps */
        }
        pool_workers++;
    }
}

int32_t lyric_parallel_threads(void) {
    pool_call_once(&pool_once, pool_init);
    return pool_workers + 1;
}

void lyric_parallel_for(int64_t count, void (*body)(int64_t, void*), void* ud) {
    if (count <= 0) {
        return;
    }
    pool_call_once(&pool_once, pool_init);
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

    pool_lock(&submit_mu);
    pool_lock(&mu);
    current_job = &job;
    generation++;
    pool_broadcast(&work_cv);
    pool_unlock(&mu);

    run_share(&job);

    pool_lock(&mu);
    while (atomic_load_explicit(&job.done, memory_order_acquire) < count || active_workers > 0) {
        pool_wait(&done_cv, &mu);
    }
    current_job = NULL;
    pool_unlock(&mu);
    pool_unlock(&submit_mu);
}

#endif
