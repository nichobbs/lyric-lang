/* lyric_posix.c — platform helpers that abstract POSIX constants and
 * struct layouts that differ between the Phase 1 targets (Linux
 * x86-64/AArch64, macOS AArch64).  See native/plan/05-ffi-design.md.
 */
#if defined(__linux__)
/* clock_gettime needs POSIX.1-2008; getrandom(2) needs _DEFAULT_SOURCE. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
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

int32_t lyric_mutex_size(void) {
    return (int32_t)sizeof(pthread_mutex_t);
}

void lyric_mutex_init(void* m) {
    if (pthread_mutex_init((pthread_mutex_t*)m, 0) != 0) {
        lyric_panic_msg("pthread_mutex_init failed", "lyric_posix.c", __LINE__);
    }
}

void lyric_mutex_lock(void* m) {
    if (pthread_mutex_lock((pthread_mutex_t*)m) != 0) {
        lyric_panic_msg("pthread_mutex_lock failed", "lyric_posix.c", __LINE__);
    }
}

void lyric_mutex_unlock(void* m) {
    if (pthread_mutex_unlock((pthread_mutex_t*)m) != 0) {
        lyric_panic_msg("pthread_mutex_unlock failed", "lyric_posix.c", __LINE__);
    }
}

void lyric_mutex_destroy(void* m) {
    pthread_mutex_destroy((pthread_mutex_t*)m);
}

int64_t lyric_epoch_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
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

int32_t lyric_secure_random(uint8_t* buf, int64_t n) {
#if defined(__APPLE__)
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
        if (got < 0) return -1;
        off += got;
    }
    return 0;
#endif
}
