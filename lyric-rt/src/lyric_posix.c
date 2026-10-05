/* lyric_posix.c — platform helpers that abstract POSIX constants and
 * struct layouts that differ between the Phase 1 targets (Linux
 * x86-64/AArch64, macOS AArch64).  See native/plan/05-ffi-design.md.
 */
#if defined(__linux__) || defined(__wasi__)
/* clock_gettime needs POSIX.1-2008; getrandom(2) needs _DEFAULT_SOURCE
 * (wasi-libc gates its POSIX declarations the same way). */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#if !defined(__wasi__)
#include <pthread.h>
#endif
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#if defined(__wasi__)
/* getentropy is declared in <unistd.h>. */
#elif defined(__linux__)
#include <sys/random.h>
#elif defined(__APPLE__)
#include <sys/random.h>
#include <unistd.h>
#endif

static void write_all(int32_t fd, const uint8_t* data, int64_t len) {
    int64_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, data + off, (size_t)(len - off));
        if (n < 0) {
            if (errno == EINTR) continue;
            return; /* best-effort: console output never panics */
        }
        if (n == 0) return; /* no progress (unusual fd); don't spin */
        off += n;
    }
}

void lyric_console_write(int32_t fd, LyricString* s) {
    if (!s || s->len == 0) return;
    write_all(fd, LYRIC_STRING_DATA(s), s->len);
}

void lyric_console_write_newline(int32_t fd) {
    static const uint8_t nl = '\n';
    write_all(fd, &nl, 1);
}

void lyric_console_write_bytes(int32_t fd, LyricList* data) {
    int64_t len = data ? data->len : 0;
    if (len <= 0) return;
    uint8_t* buf = (uint8_t*)malloc((size_t)len);
    if (!buf) return; /* best-effort: console output never panics */
    for (int64_t i = 0; i < len; i++) {
        buf[i] = (uint8_t)(data->data[i] & 0xff);
    }
    write_all(fd, buf, len);
    free(buf);
}

void lyric_console_write_line(int32_t fd, LyricString* s) {
    static const uint8_t nl = '\n';
    int64_t len = s ? s->len : 0;
    if (len == 0) {
        write_all(fd, &nl, 1);
        return;
    }
    /* One writev(2) for the text and its newline: half the syscalls of two
     * writes, and a whole line per call, so concurrent printers don't
     * split a line from its newline. A partial write falls back to
     * write_all for whatever remains. */
    struct iovec iov[2];
    iov[0].iov_base = (void*)LYRIC_STRING_DATA(s);
    iov[0].iov_len = (size_t)len;
    iov[1].iov_base = (void*)&nl;
    iov[1].iov_len = 1;
    ssize_t n;
    do {
        n = writev(fd, iov, 2);
    } while (n < 0 && errno == EINTR);
    if (n < 0) return; /* best-effort: console output never panics */
    if (n < len) {
        write_all(fd, LYRIC_STRING_DATA(s) + n, len - n);
        write_all(fd, &nl, 1);
    } else if (n == len) {
        write_all(fd, &nl, 1);
    }
}

/* ── Console input ───────────────────────────────────────────────────
 * Every read goes straight to fd 0 with no user-space buffer, so a line
 * read consumes nothing past its terminator and the raw-byte reader never
 * misses bytes a line read could have buffered.  The one exception is the
 * byte after a bare '\r': a line ending is "\n", "\r\n" or a lone '\r', so
 * the line reader must look one byte ahead, and keeps that byte here for
 * the next read of either kind.  Std.Console allows one stdin reader per
 * process, so this state is not locked. */
static int32_t stdin_pending = -1;

/* One read(2) of up to `cap` bytes, retried on EINTR: >0 bytes, 0 at end
 * of stream, -1 on error. */
static ssize_t stdin_read_raw(uint8_t* buf, size_t cap) {
    for (;;) {
        ssize_t n = read(STDIN_FILENO, buf, cap);
        if (n >= 0) return n;
        if (errno != EINTR) return -1;
    }
}

int32_t lyric_stdin_wait(int32_t timeout_ms) {
    if (stdin_pending >= 0) return 1;
    int64_t deadline = timeout_ms >= 0
        ? lyric_monotonic_nanos() + (int64_t)timeout_ms * 1000000
        : 0;
    for (;;) {
        int wait_ms = -1;
        if (timeout_ms >= 0) {
            int64_t left = deadline - lyric_monotonic_nanos();
            wait_ms = left <= 0 ? 0 : (int)((left + 999999) / 1000000);
        }
        struct pollfd pfd;
        pfd.fd = STDIN_FILENO;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int rc = poll(&pfd, 1, wait_ms);
        if (rc > 0) {
            /* End of stream (POLLHUP) and a pending error both make the
             * next read return at once, so they count as ready. */
            return 1;
        }
        if (rc == 0) return 0;
        if (errno != EINTR) return -1;
    }
}

LyricList* lyric_stdin_read(int32_t max, int32_t* ok) {
    if (max <= 0) {
        *ok = 1;
        return lyric_list_from_bytes(NULL, 0);
    }
    uint8_t* buf = (uint8_t*)malloc((size_t)max);
    if (!buf) lyric_panic_msg("out of memory reading stdin", "lyric_posix.c", __LINE__);
    int64_t n = 0;
    if (stdin_pending >= 0) {
        buf[n++] = (uint8_t)stdin_pending;
        stdin_pending = -1;
    } else {
        ssize_t got = stdin_read_raw(buf, (size_t)max);
        if (got < 0) {
            free(buf);
            *ok = 0;
            return lyric_list_from_bytes(NULL, 0);
        }
        n = (int64_t)got;
    }
    LyricList* list = lyric_list_from_bytes(buf, n);
    free(buf);
    *ok = 1;
    return list;
}

int32_t lyric_stdin_read_line(LyricString** out) {
    int64_t cap = 128;
    int64_t len = 0;
    uint8_t* buf = (uint8_t*)malloc((size_t)cap);
    if (!buf) lyric_panic_msg("out of memory reading stdin", "lyric_posix.c", __LINE__);
    int32_t result = 1;
    for (;;) {
        uint8_t b;
        if (stdin_pending >= 0) {
            b = (uint8_t)stdin_pending;
            stdin_pending = -1;
        } else {
            ssize_t got = stdin_read_raw(&b, 1);
            if (got < 0) {
                result = -1;
                break;
            }
            if (got == 0) {
                if (len == 0) result = 0;
                break;
            }
        }
        if (b == '\n') break;
        if (b == '\r') {
            uint8_t next;
            ssize_t got = stdin_read_raw(&next, 1);
            if (got < 0) {
                result = -1;
                break;
            }
            if (got == 1 && next != '\n') stdin_pending = next;
            break;
        }
        if (len == cap) {
            cap *= 2;
            uint8_t* grown = (uint8_t*)realloc(buf, (size_t)cap);
            if (!grown) {
                free(buf);
                lyric_panic_msg("out of memory reading stdin", "lyric_posix.c", __LINE__);
            }
            buf = grown;
        }
        buf[len++] = b;
    }
    if (result == 1) *out = lyric_string_from_literal(buf, len);
    free(buf);
    return result;
}

int32_t lyric_o_rdonly(void) { return O_RDONLY; }
int32_t lyric_o_wronly(void) { return O_WRONLY; }
int32_t lyric_o_rdwr(void)   { return O_RDWR; }
int32_t lyric_o_creat(void)  { return O_CREAT; }
int32_t lyric_o_trunc(void)  { return O_TRUNC; }
int32_t lyric_o_append(void) { return O_APPEND; }

int64_t lyric_file_size(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    return (int64_t)st.st_size;
}

/* Fixed-width wrappers for the libc entry points whose C signatures use
 * size_t / ssize_t or are variadic.  Those types are 32-bit on wasm32, so a
 * Lyric extern declaring them as `Long` would not match the C signature
 * there; these always take and return int64_t / int32_t on every target. */
int64_t lyric_write_fd(int32_t fd, const void* buf, int64_t n) {
    return (int64_t)write(fd, buf, (size_t)n);
}

int64_t lyric_read_fd(int32_t fd, void* buf, int64_t n) {
    return (int64_t)read(fd, buf, (size_t)n);
}

/* open(2) is variadic, so it cannot be declared as a plain extern. */
int32_t lyric_open_fd(const char* path, int32_t flags, int32_t mode) {
    return (int32_t)open(path, flags, (mode_t)mode);
}

int64_t lyric_cstr_len(const char* s) {
    return (int64_t)strlen(s);
}

void* lyric_malloc_raw(int64_t n) {
    return malloc((size_t)n);
}

#if defined(__wasi__)
/* wasm32-wasi runs a single thread (docs/35 §5.2, D-progress-1028): there is
 * no other thread to exclude, so a protected type's lock is a nesting-depth
 * counter that keeps lock/unlock pairs balanced across a member that calls a
 * sibling.  Releasing a lock that is not held, or waiting on a semaphore no
 * one can post, would otherwise hang or corrupt state, so both panic. */
typedef struct {
    int32_t depth;
} lyric_wasm_mutex_t;

int32_t lyric_mutex_size(void) {
    return (int32_t)sizeof(lyric_wasm_mutex_t);
}

void lyric_mutex_init(void* m) {
    ((lyric_wasm_mutex_t*)m)->depth = 0;
}

void lyric_mutex_lock(void* m) {
    ((lyric_wasm_mutex_t*)m)->depth += 1;
}

void lyric_mutex_unlock(void* m) {
    lyric_wasm_mutex_t* mu = (lyric_wasm_mutex_t*)m;
    if (mu->depth <= 0) {
        lyric_panic_msg("unlock of a lock that is not held", "lyric_posix.c", __LINE__);
    }
    mu->depth -= 1;
}

void lyric_mutex_destroy(void* m) {
    (void)m;
}

void lyric_mutex_wait(void* m) {
    (void)m;
    lyric_panic_msg("a `when:` barrier is false and no other thread can make it true", "lyric_posix.c", __LINE__);
}

void lyric_mutex_notify_all(void* m) {
    (void)m;
}

typedef struct {
    int32_t count;
} lyric_sem_t;

int32_t lyric_sem_size(void) {
    return (int32_t)sizeof(lyric_sem_t);
}

void lyric_sem_init(void* s, int32_t initial) {
    ((lyric_sem_t*)s)->count = initial;
}

void lyric_sem_wait(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    if (sem->count <= 0) {
        lyric_panic_msg("semaphore wait would block forever: no other thread can post on wasm32-wasi",
                        "lyric_posix.c", __LINE__);
    }
    sem->count -= 1;
}

int32_t lyric_sem_trywait(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    if (sem->count <= 0) return 0;
    sem->count -= 1;
    return 1;
}

void lyric_sem_post(void* s) {
    ((lyric_sem_t*)s)->count += 1;
}

void lyric_sem_destroy(void* s) {
    (void)s;
}

typedef struct {
    int32_t unused;
} lyric_wasm_cond_t;

int32_t lyric_cond_size(void) {
    return (int32_t)sizeof(lyric_wasm_cond_t);
}

void lyric_cond_init(void* c) {
    ((lyric_wasm_cond_t*)c)->unused = 0;
}

void lyric_cond_wait(void* c, void* m) {
    (void)c;
    (void)m;
    lyric_panic_msg("wait on a condition no other thread can signal", "lyric_posix.c", __LINE__);
}

int32_t lyric_cond_timedwait(void* c, void* m, int64_t timeout_ns) {
    (void)c;
    (void)m;
    if (timeout_ns > 0) {
        struct timespec ts;
        ts.tv_sec = (time_t)(timeout_ns / 1000000000LL);
        ts.tv_nsec = (long)(timeout_ns % 1000000000LL);
        nanosleep(&ts, 0);
    }
    return 0;
}

void lyric_cond_signal(void* c) {
    (void)c;
}

void lyric_cond_broadcast(void* c) {
    (void)c;
}

void lyric_cond_destroy(void* c) {
    (void)c;
}

#else
/* A protected type's lock is a monitor: a mutex, the condition its `when:`
 * barriers wait on, and who holds it and how deeply.  It is reentrant (a
 * member may call a sibling member, which takes the same instance lock again,
 * docs/01 §7.5; the CLR Monitor and JVM object monitors are reentrant too),
 * and a wait releases EVERY level at once and restores the depth on return,
 * which a pthread recursive mutex cannot do (pthread_cond_wait releases a
 * single level).  `owner` and `depth` are read without the mutex only to ask
 * "does this thread already hold it?", which no other thread can make true. */
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    pthread_t owner;
    int32_t depth;
} lyric_monitor_t;

int32_t lyric_mutex_size(void) {
    return (int32_t)sizeof(lyric_monitor_t);
}

void lyric_mutex_init(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (pthread_mutex_init(&mon->mutex, 0) != 0) {
        lyric_panic_msg("pthread_mutex_init failed", "lyric_posix.c", __LINE__);
    }
    if (pthread_cond_init(&mon->cond, 0) != 0) {
        lyric_panic_msg("pthread_cond_init failed", "lyric_posix.c", __LINE__);
    }
    mon->depth = 0;
}

static int lyric_monitor_held_by_me(lyric_monitor_t* mon) {
    return __atomic_load_n(&mon->depth, __ATOMIC_RELAXED) > 0 && pthread_equal(mon->owner, pthread_self());
}

void lyric_mutex_lock(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (lyric_monitor_held_by_me(mon)) {
        mon->depth += 1;
        return;
    }
    if (pthread_mutex_lock(&mon->mutex) != 0) {
        lyric_panic_msg("pthread_mutex_lock failed", "lyric_posix.c", __LINE__);
    }
    mon->owner = pthread_self();
    __atomic_store_n(&mon->depth, 1, __ATOMIC_RELAXED);
}

void lyric_mutex_unlock(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("unlock of a lock that is not held", "lyric_posix.c", __LINE__);
    }
    if (mon->depth > 1) {
        mon->depth -= 1;
        return;
    }
    __atomic_store_n(&mon->depth, 0, __ATOMIC_RELAXED);
    if (pthread_mutex_unlock(&mon->mutex) != 0) {
        lyric_panic_msg("pthread_mutex_unlock failed", "lyric_posix.c", __LINE__);
    }
}

void lyric_mutex_destroy(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    pthread_cond_destroy(&mon->cond);
    pthread_mutex_destroy(&mon->mutex);
}

/* Release every level, wait, and take them all back.  The wait is the single
 * atomic release-and-block of pthread_cond_wait, so a notify between the
 * caller's test of its barrier and the wait is not lost. */
void lyric_mutex_wait(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("wait on a lock that is not held", "lyric_posix.c", __LINE__);
    }
    int32_t saved = mon->depth;
    __atomic_store_n(&mon->depth, 0, __ATOMIC_RELAXED);
    if (pthread_cond_wait(&mon->cond, &mon->mutex) != 0) {
        lyric_panic_msg("pthread_cond_wait failed", "lyric_posix.c", __LINE__);
    }
    mon->owner = pthread_self();
    __atomic_store_n(&mon->depth, saved, __ATOMIC_RELAXED);
}

void lyric_mutex_notify_all(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("notify on a lock that is not held", "lyric_posix.c", __LINE__);
    }
    if (pthread_cond_broadcast(&mon->cond) != 0) {
        lyric_panic_msg("pthread_cond_broadcast failed", "lyric_posix.c", __LINE__);
    }
}

/* Counting semaphore: a mutex + condvar + count, rather than POSIX
 * sem_init (unnamed process-private semaphores are not implemented on
 * macOS — sem_init there always fails with ENOSYS). Mirrors the
 * lyric_mutex_* shape above. */
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int32_t count;
} lyric_sem_t;

int32_t lyric_sem_size(void) {
    return (int32_t)sizeof(lyric_sem_t);
}

void lyric_sem_init(void* s, int32_t initial) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    if (pthread_mutex_init(&sem->mutex, 0) != 0) {
        lyric_panic_msg("pthread_mutex_init (sem) failed", "lyric_posix.c", __LINE__);
    }
    if (pthread_cond_init(&sem->cond, 0) != 0) {
        lyric_panic_msg("pthread_cond_init (sem) failed", "lyric_posix.c", __LINE__);
    }
    sem->count = initial;
}

void lyric_sem_wait(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    if (pthread_mutex_lock(&sem->mutex) != 0) {
        lyric_panic_msg("pthread_mutex_lock (sem) failed", "lyric_posix.c", __LINE__);
    }
    while (sem->count <= 0) {
        if (pthread_cond_wait(&sem->cond, &sem->mutex) != 0) {
            lyric_panic_msg("pthread_cond_wait (sem) failed", "lyric_posix.c", __LINE__);
        }
    }
    sem->count -= 1;
    if (pthread_mutex_unlock(&sem->mutex) != 0) {
        lyric_panic_msg("pthread_mutex_unlock (sem) failed", "lyric_posix.c", __LINE__);
    }
}

/* Non-blocking variant of lyric_sem_wait: decrements and returns 1 only
 * if the count is already positive, otherwise leaves the count alone and
 * returns 0 immediately. Lets a caller drain exactly the credits that are
 * genuinely unclaimed right now without ever waiting on a post nothing
 * will ever send — the shape _kernel_native/http_server.l's
 * stopListener needs to retire an abandoned-but-still-queued request
 * without stealing a credit a concurrently racing dequeueContext caller
 * already consumed (#6796). */
int32_t lyric_sem_trywait(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    int32_t acquired = 0;
    if (pthread_mutex_lock(&sem->mutex) != 0) {
        lyric_panic_msg("pthread_mutex_lock (sem) failed", "lyric_posix.c", __LINE__);
    }
    if (sem->count > 0) {
        sem->count -= 1;
        acquired = 1;
    }
    if (pthread_mutex_unlock(&sem->mutex) != 0) {
        lyric_panic_msg("pthread_mutex_unlock (sem) failed", "lyric_posix.c", __LINE__);
    }
    return acquired;
}

void lyric_sem_post(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    if (pthread_mutex_lock(&sem->mutex) != 0) {
        lyric_panic_msg("pthread_mutex_lock (sem) failed", "lyric_posix.c", __LINE__);
    }
    sem->count += 1;
    if (pthread_cond_signal(&sem->cond) != 0) {
        lyric_panic_msg("pthread_cond_signal (sem) failed", "lyric_posix.c", __LINE__);
    }
    if (pthread_mutex_unlock(&sem->mutex) != 0) {
        lyric_panic_msg("pthread_mutex_unlock (sem) failed", "lyric_posix.c", __LINE__);
    }
}

void lyric_sem_destroy(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    pthread_cond_destroy(&sem->cond);
    pthread_mutex_destroy(&sem->mutex);
}

/* Condition variables (see lyric_rt.h).  Timed waits run on the monotonic
 * clock, so a wall-clock step cannot cut one short or stretch it: glibc and
 * musl take the clock as a condattr, macOS has no such attribute but offers a
 * relative-timeout wait. */
static void lyric_cond_init_raw(pthread_cond_t* cv) {
    pthread_condattr_t attr;
    if (pthread_condattr_init(&attr) != 0) {
        lyric_panic_msg("pthread_condattr_init failed", "lyric_posix.c", __LINE__);
    }
#if !defined(__APPLE__)
    if (pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) != 0) {
        lyric_panic_msg("pthread_condattr_setclock failed", "lyric_posix.c", __LINE__);
    }
#endif
    if (pthread_cond_init(cv, &attr) != 0) {
        lyric_panic_msg("pthread_cond_init failed", "lyric_posix.c", __LINE__);
    }
    pthread_condattr_destroy(&attr);
}

static void lyric_cond_wait_raw(pthread_cond_t* cv, pthread_mutex_t* mu) {
    if (pthread_cond_wait(cv, mu) != 0) {
        lyric_panic_msg("pthread_cond_wait failed", "lyric_posix.c", __LINE__);
    }
}

static int32_t lyric_cond_timedwait_raw(pthread_cond_t* cv, pthread_mutex_t* mu, int64_t timeout_ns) {
    if (timeout_ns <= 0) {
        return 0;
    }
    int rc;
#if defined(__APPLE__)
    struct timespec rel;
    rel.tv_sec = (time_t)(timeout_ns / 1000000000LL);
    rel.tv_nsec = (long)(timeout_ns % 1000000000LL);
    rc = pthread_cond_timedwait_relative_np(cv, mu, &rel);
#else
    struct timespec abs;
    clock_gettime(CLOCK_MONOTONIC, &abs);
    int64_t nsec = (int64_t)abs.tv_nsec + timeout_ns % 1000000000LL;
    abs.tv_sec += (time_t)(timeout_ns / 1000000000LL + nsec / 1000000000LL);
    abs.tv_nsec = (long)(nsec % 1000000000LL);
    rc = pthread_cond_timedwait(cv, mu, &abs);
#endif
    if (rc == ETIMEDOUT) {
        return 0;
    }
    if (rc != 0) {
        lyric_panic_msg("pthread_cond_timedwait failed", "lyric_posix.c", __LINE__);
    }
    return 1;
}

int32_t lyric_cond_size(void) {
    return (int32_t)sizeof(pthread_cond_t);
}

void lyric_cond_init(void* c) {
    lyric_cond_init_raw((pthread_cond_t*)c);
}

void lyric_cond_wait(void* c, void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("wait on a lock that is not held", "lyric_posix.c", __LINE__);
    }
    int32_t saved = mon->depth;
    __atomic_store_n(&mon->depth, 0, __ATOMIC_RELAXED);
    lyric_cond_wait_raw((pthread_cond_t*)c, &mon->mutex);
    mon->owner = pthread_self();
    __atomic_store_n(&mon->depth, saved, __ATOMIC_RELAXED);
}

int32_t lyric_cond_timedwait(void* c, void* m, int64_t timeout_ns) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("wait on a lock that is not held", "lyric_posix.c", __LINE__);
    }
    int32_t saved = mon->depth;
    __atomic_store_n(&mon->depth, 0, __ATOMIC_RELAXED);
    int32_t woke = lyric_cond_timedwait_raw((pthread_cond_t*)c, &mon->mutex, timeout_ns);
    mon->owner = pthread_self();
    __atomic_store_n(&mon->depth, saved, __ATOMIC_RELAXED);
    return woke;
}

void lyric_cond_signal(void* c) {
    if (pthread_cond_signal((pthread_cond_t*)c) != 0) {
        lyric_panic_msg("pthread_cond_signal failed", "lyric_posix.c", __LINE__);
    }
}

void lyric_cond_broadcast(void* c) {
    if (pthread_cond_broadcast((pthread_cond_t*)c) != 0) {
        lyric_panic_msg("pthread_cond_broadcast failed", "lyric_posix.c", __LINE__);
    }
}

void lyric_cond_destroy(void* c) {
    pthread_cond_destroy((pthread_cond_t*)c);
}

#endif /* __wasi__ */

int64_t lyric_epoch_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Full-resolution wall clock for the native Std.Time Instant
 * representation (nanoseconds since the Unix epoch, D-N-027).  The
 * int64 range covers years ~1678..2262, the same window
 * java.time.Duration.toNanos() lives in. */
int64_t lyric_epoch_nanos(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

int64_t lyric_monotonic_nanos(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

/* A version-4 (random) UUID as its canonical lowercase hyphenated
 * 36-char string (RFC 4122 §4.4: 122 random bits, version nibble 4,
 * variant bits 10).  The string IS the native Uuid representation
 * (D-N-026), so formatting happens here, once.  Entropy failure is a
 * panic: a "random" UUID from a broken RNG is a correctness bug, not
 * a recoverable condition. */
LyricString* lyric_uuid_v4(void) {
    uint8_t b[16];
    if (lyric_secure_random(b, 16) != 0) {
        lyric_panic_msg("cannot draw entropy for a v4 UUID", "lyric_posix.c", __LINE__);
    }
    b[6] = (uint8_t)((b[6] & 0x0F) | 0x40);
    b[8] = (uint8_t)((b[8] & 0x3F) | 0x80);
    static const char hex[] = "0123456789abcdef";
    char out[36];
    int o = 0;
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) out[o++] = '-';
        out[o++] = hex[b[i] >> 4];
        out[o++] = hex[b[i] & 0x0F];
    }
    return lyric_string_from_literal((const uint8_t*)out, 36);
}

LyricList* lyric_secure_random_list(int64_t n) {
    if (n < 0) {
        lyric_panic_msg("secure random byte count must not be negative", "lyric_posix.c", __LINE__);
    }
    uint8_t* buf = (uint8_t*)malloc(n > 0 ? (size_t)n : 1);
    if (buf == NULL) {
        lyric_panic_msg("out of memory drawing secure random bytes", "lyric_posix.c", __LINE__);
    }
    if (lyric_secure_random(buf, n) != 0) {
        free(buf);
        lyric_panic_msg("cannot draw entropy from the OS", "lyric_posix.c", __LINE__);
    }
    LyricList* list = lyric_list_from_bytes(buf, n);
    free(buf);
    return list;
}

int32_t lyric_secure_random(uint8_t* buf, int64_t n) {
#if defined(__APPLE__) || defined(__wasi__)
    /* getentropy caps each call at 256 bytes. */
    int64_t off = 0;
    while (off < n) {
        int64_t chunk = n - off > 256 ? 256 : n - off;
        if (getentropy(buf + off, (size_t)chunk) != 0) return -1;
        off += chunk;
    }
    return 0;
#else
    int64_t off = 0;
    while (off < n) {
        ssize_t got = getrandom(buf + off, (size_t)(n - off), 0);
        if (got < 0) {
            /* getrandom can be interrupted by a signal before drawing any
             * bytes; that is retryable, not an entropy failure.  Treating
             * EINTR as fatal made a stray signal during UUID generation
             * abort the whole process (lyric_uuid_v4 panics on -1). */
            if (errno == EINTR) continue;
            return -1;
        }
        off += got;
    }
    return 0;
#endif
}

#if !defined(__wasi__)
int32_t lyric_thread_create(int64_t* tid, void* (*start)(void*), void* arg) {
    pthread_t t;
    int rc = pthread_create(&t, NULL, start, arg);
    if (rc == 0) {
        *tid = (int64_t)(uintptr_t)t;
    }
    return (int32_t)rc;
}

int32_t lyric_thread_join(int64_t tid, void** retval) {
    return (int32_t)pthread_join((pthread_t)(uintptr_t)tid, retval);
}

typedef struct {
    void* (*start)(void*);
    void* arg;
} lyric_detached_start;

static void* lyric_detached_entry(void* p) {
    lyric_detached_start s = *(lyric_detached_start*)p;
    free(p);
    s.start(s.arg);
    lyric_release(s.arg);
    return NULL;
}

int32_t lyric_thread_spawn_detached(void* (*start)(void*), void* arg) {
    lyric_detached_start* s = (lyric_detached_start*)malloc(sizeof *s);
    if (s == NULL) return ENOMEM;
    s->start = start;
    s->arg = arg;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t t;
    int rc = pthread_create(&t, &attr, lyric_detached_entry, s);
    pthread_attr_destroy(&attr);
    if (rc != 0) free(s);
    return (int32_t)rc;
}

static pthread_mutex_t lyric_global_mutex = PTHREAD_MUTEX_INITIALIZER;

void lyric_global_lock(void) {
    pthread_mutex_lock(&lyric_global_mutex);
}

void lyric_global_unlock(void) {
    pthread_mutex_unlock(&lyric_global_mutex);
}

static pthread_cond_t lyric_global_cond_var;
static pthread_once_t lyric_global_cond_once = PTHREAD_ONCE_INIT;

static void lyric_global_cond_setup(void) {
    lyric_cond_init_raw(&lyric_global_cond_var);
}

void lyric_global_cond_wait(void) {
    pthread_once(&lyric_global_cond_once, lyric_global_cond_setup);
    lyric_cond_wait_raw(&lyric_global_cond_var, &lyric_global_mutex);
}

int32_t lyric_global_cond_timedwait(int64_t timeout_ns) {
    pthread_once(&lyric_global_cond_once, lyric_global_cond_setup);
    return lyric_cond_timedwait_raw(&lyric_global_cond_var, &lyric_global_mutex, timeout_ns);
}

void lyric_global_cond_broadcast(void) {
    pthread_once(&lyric_global_cond_once, lyric_global_cond_setup);
    pthread_cond_broadcast(&lyric_global_cond_var);
}

static _Thread_local void* lyric_tl_ref = NULL;

void lyric_thread_ref_set(void* obj) {
    void* previous = lyric_tl_ref;
    if (obj != NULL) lyric_retain(obj);
    lyric_tl_ref = obj;
    if (previous != NULL) lyric_release(previous);
}

void* lyric_thread_ref_get(void) {
    if (lyric_tl_ref != NULL) lyric_retain(lyric_tl_ref);
    return lyric_tl_ref;
}

void lyric_thread_ref_clear(void) {
    lyric_thread_ref_set(NULL);
}

int32_t lyric_thread_ref_has(void) {
    return lyric_tl_ref != NULL ? 1 : 0;
}

#endif
