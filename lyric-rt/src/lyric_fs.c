/* lyric_fs.c — file, directory, and environment helpers for the
 * Phase N5 stdlib port (Std.File, Std.Directory, Std.Environment).
 * See native/plan/05-ffi-design.md and native/plan/07-stdlib-port.md.
 *
 * Every failure here is environmental (missing path, permissions, ...):
 * these functions return -1/0/NULL rather than panicking, matching the
 * console/platform helpers in lyric_posix.c.
 */
#if defined(__linux__)
/* dirent's d_name / getcwd's ERANGE handling need POSIX.1-2008. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ── Files ─────────────────────────────────────────────────────────── */

int32_t lyric_file_open(const char* path, int32_t flags, int32_t mode) {
    for (;;) {
        int fd = open(path, flags, mode);
        if (fd >= 0) return fd;
        if (errno == EINTR) continue;
        return -1;
    }
}

int32_t lyric_file_close(int32_t fd) {
    return close(fd) == 0 ? 0 : -1;
}

LyricString* lyric_file_read_all(const char* path) {
    int fd;
    for (;;) {
        fd = open(path, O_RDONLY);
        if (fd >= 0) break;
        if (errno == EINTR) continue;
        return NULL;
    }

    struct stat st;
    int64_t cap = 4096;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0) {
        cap = (int64_t)st.st_size;
    }
    uint8_t* buf = (uint8_t*)malloc((size_t)cap);
    if (!buf) {
        close(fd);
        return NULL;
    }

    int64_t len = 0;
    for (;;) {
        if (len == cap) {
            if (cap > INT64_MAX / 2) { /* doubling would overflow (UB) */
                free(buf);
                close(fd);
                return NULL;
            }
            cap *= 2;
            uint8_t* nb = (uint8_t*)realloc(buf, (size_t)cap);
            if (!nb) {
                free(buf);
                close(fd);
                return NULL;
            }
            buf = nb;
        }
        ssize_t n = read(fd, buf + len, (size_t)(cap - len));
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            close(fd);
            return NULL;
        }
        if (n == 0) break; /* EOF */
        len += n;
    }
    close(fd);

    LyricString* s = lyric_string_from_literal(buf, len);
    free(buf);
    return s;
}

int32_t lyric_file_read_all_ok(const char* path, LyricString** out) {
    LyricString* s = lyric_file_read_all(path);
    if (!s) return -1;
    *out = s;
    return 0;
}

int32_t lyric_file_write_all(const char* path, LyricString* data, int32_t append) {
    int flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC);
    int fd;
    for (;;) {
        fd = open(path, flags, 0644);
        if (fd >= 0) break;
        if (errno == EINTR) continue;
        return -1;
    }

    int64_t len = data ? data->len : 0;
    const uint8_t* p = len > 0 ? LYRIC_STRING_DATA(data) : NULL;
    int64_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, p + off, (size_t)(len - off));
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (n == 0) break; /* no progress; avoid spinning */
        off += n;
    }

    if (close(fd) != 0) return -1;
    return off == len ? 0 : -1;
}

int32_t lyric_file_delete(const char* path) {
    return unlink(path) == 0 ? 0 : -1;
}

int32_t lyric_file_rename(const char* old_path, const char* new_path) {
    return rename(old_path, new_path) == 0 ? 0 : -1;
}

int32_t lyric_file_exists(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISREG(st.st_mode) ? 1 : 0;
}

/* ── Directories ───────────────────────────────────────────────────── */

int32_t lyric_dir_create(const char* path) {
    return mkdir(path, 0755) == 0 ? 0 : -1;
}

int32_t lyric_dir_remove(const char* path) {
    return rmdir(path) == 0 ? 0 : -1;
}

int32_t lyric_dir_exists(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) ? 1 : 0;
}

LyricList* lyric_dir_list(const char* path) {
    DIR* d = opendir(path);
    if (!d) return NULL;

    LyricList* list = lyric_list_new(1);
    errno = 0;
    struct dirent* ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
            errno = 0;
            continue;
        }
        LyricString* name = lyric_string_from_literal(
            (const uint8_t*)ent->d_name, (int64_t)strlen(ent->d_name));
        lyric_list_push(list, (int64_t)(intptr_t)name); /* list retains it */
        lyric_release(name); /* drop this function's local reference */
        errno = 0;
    }
    /* readdir returns NULL both at end-of-stream and on error;
     * a non-zero errno after the loop means the latter. */
    if (errno != 0) {
        lyric_release(list);
        closedir(d);
        return NULL;
    }
    closedir(d);
    return list;
}

/* ── Environment ───────────────────────────────────────────────────── */

LyricString* lyric_env_get(const char* name) {
    const char* v = getenv(name);
    if (!v) return NULL;
    return lyric_string_from_literal((const uint8_t*)v, (int64_t)strlen(v));
}

int32_t lyric_env_get_ok(const char* name, LyricString** out) {
    LyricString* s = lyric_env_get(name);
    if (!s) return -1;
    *out = s;
    return 0;
}

int32_t lyric_env_set(const char* name, const char* value) {
    return setenv(name, value, 1) == 0 ? 0 : -1;
}

LyricString* lyric_env_cwd(void) {
    size_t cap = 256;
    char* buf = (char*)malloc(cap);
    if (!buf) return NULL;
    for (;;) {
        if (getcwd(buf, cap) != NULL) break;
        if (errno != ERANGE) {
            free(buf);
            return NULL;
        }
        if (cap > SIZE_MAX / 2) { /* doubling would wrap (getcwd would spin forever) */
            free(buf);
            return NULL;
        }
        cap *= 2;
        char* nb = (char*)realloc(buf, cap);
        if (!nb) {
            free(buf);
            return NULL;
        }
        buf = nb;
    }
    LyricString* s = lyric_string_from_literal((const uint8_t*)buf, (int64_t)strlen(buf));
    free(buf);
    return s;
}

int32_t lyric_env_cwd_ok(LyricString** out) {
    LyricString* s = lyric_env_cwd();
    if (!s) return -1;
    *out = s;
    return 0;
}
