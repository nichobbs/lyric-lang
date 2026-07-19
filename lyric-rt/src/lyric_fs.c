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

/* Read the whole file at `path` into a fresh malloc'd buffer; the caller
 * owns it and must free().  Writes the byte count through *out_len and
 * returns the buffer (possibly zero-length, never NULL on success), or
 * NULL on any open/read/allocation failure.  Shared by
 * lyric_file_read_all and lyric_file_read_bytes so neither pays for the
 * other's representation. */
static uint8_t* read_file_to_buf(const char* path, int64_t* out_len) {
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
    *out_len = len;
    return buf;
}

LyricString* lyric_file_read_all(const char* path) {
    int64_t len = 0;
    uint8_t* buf = read_file_to_buf(path, &len);
    if (!buf) return NULL;
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

/* Whole-file read as a scalar LyricList with one byte per 64-bit slot.
 * The 8x slot width is the documented Phase-1 tradeoff for reusing the
 * single list layout (D-N-015); a packed byte-array representation is
 * a future optimisation.  ALWAYS returns a fresh rc=1 list (empty on
 * failure) and reports success through *ok (1/0) — the Lyric kernel
 * binds the returned owned list directly, avoiding the out-param slot
 * protocol that would leak a ref-typed initialiser. */
LyricList* lyric_file_read_bytes(const char* path, int32_t* ok) {
    LyricList* list = lyric_list_new(0);
    int64_t len = 0;
    uint8_t* buf = read_file_to_buf(path, &len);
    if (!buf) {
        *ok = 0;
        return list;
    }
    /* Read straight into the list — no intermediate LyricString (#4834). */
    for (int64_t i = 0; i < len; i++) {
        lyric_list_push(list, (int64_t)buf[i]);
    }
    free(buf);
    *ok = 1;
    return list;
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

/* Write every byte (one per 64-bit slot, D-N-015) of `data` to `path`,
 * creating (mode 0644) or truncating; append != 0 appends.  Returns 0
 * on success, -1 on failure. */
int32_t lyric_file_write_bytes(const char* path, LyricList* data, int32_t append) {
    int64_t len = data ? data->len : 0;
    uint8_t* buf = NULL;
    if (len > 0) {
        buf = (uint8_t*)malloc((size_t)len);
        if (!buf) return -1;
        for (int64_t i = 0; i < len; i++) buf[i] = (uint8_t)data->data[i];
    }
    int flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC);
    int fd;
    for (;;) {
        fd = open(path, flags, 0644);
        if (fd >= 0) break;
        if (errno == EINTR) continue;
        free(buf);
        return -1;
    }
    int64_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, (size_t)(len - off));
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            close(fd);
            return -1;
        }
        if (n == 0) break;
        off += n;
    }
    free(buf);
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

int32_t lyric_path_is_dir_nofollow(const char* path) {
    /* lstat, so a symlink-to-directory is NOT a directory here — a
     * recursive delete must unlink such a link, never descend into its
     * target (which may lie outside the tree being removed). */
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
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

/* Entry-name listing with the return-plus-ok-flag protocol (see
 * lyric_file_read_bytes): always a fresh rc=1 list, empty on failure,
 * *ok reporting success. */
LyricList* lyric_dir_list2(const char* path, int32_t* ok) {
    LyricList* l = lyric_dir_list(path);
    if (!l) {
        *ok = 0;
        return lyric_list_new(1);
    }
    *ok = 1;
    return l;
}

/* Classifies one directory entry as LYRIC_DIRENT_{OTHER,DIR,REG}.
 * `full_path` must be the entry's joined path (dir + "/" + d_name) so
 * the DT_LNK / DT_UNKNOWN fallback can stat(2) it — a FOLLOWING stat,
 * matching lyric_file_exists / lyric_dir_exists, so a symlink is
 * classified by its target's kind, exactly like the two-probe path this
 * replaces. A device/fifo/socket/whiteout entry (a known d_type that is
 * none of DT_DIR/DT_REG/DT_LNK/DT_UNKNOWN) can never resolve to a
 * regular file or directory via stat() either — it isn't a symlink, so
 * stat() sees the same node lstat() would — so it short-circuits to
 * OTHER without a syscall. */
static int32_t classify_dirent(const char* full_path, unsigned char d_type) {
    if (d_type == DT_DIR) return LYRIC_DIRENT_DIR;
    if (d_type == DT_REG) return LYRIC_DIRENT_REG;
    if (d_type == DT_LNK || d_type == DT_UNKNOWN) {
        struct stat st;
        if (stat(full_path, &st) != 0) return LYRIC_DIRENT_OTHER;
        if (S_ISDIR(st.st_mode)) return LYRIC_DIRENT_DIR;
        if (S_ISREG(st.st_mode)) return LYRIC_DIRENT_REG;
        return LYRIC_DIRENT_OTHER;
    }
    return LYRIC_DIRENT_OTHER;
}

/* Single-sweep entry-name-and-kind listing (#4856): one opendir/readdir
 * pass classifies every entry via `d_type`, falling back to stat(2) only
 * for DT_LNK / DT_UNKNOWN (see classify_dirent) instead of the caller
 * doing a full stat() per entry after a bare-name listing. Each returned
 * string is a single LYRIC_DIRENT_* ASCII digit followed by the bare
 * entry name — see the header doc comment for why this avoids a second
 * ref-typed out-param. */
LyricList* lyric_dir_list_typed(const char* path, int32_t* ok) {
    DIR* d = opendir(path);
    if (!d) {
        *ok = 0;
        return lyric_list_new(1);
    }

    LyricList* list = lyric_list_new(1);
    size_t path_len = strlen(path);
    errno = 0;
    struct dirent* ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
            errno = 0;
            continue;
        }
        size_t name_len = strlen(ent->d_name);
        char* full = (char*)malloc(path_len + 1 + name_len + 1);
        if (!full) {
            lyric_release(list);
            closedir(d);
            *ok = 0;
            return lyric_list_new(1);
        }
        memcpy(full, path, path_len);
        full[path_len] = '/';
        memcpy(full + path_len + 1, ent->d_name, name_len + 1); /* +1 copies the NUL */
        int32_t kind = classify_dirent(full, ent->d_type);
        free(full);

        uint8_t* tagged = (uint8_t*)malloc(name_len + 1);
        if (!tagged) {
            lyric_release(list);
            closedir(d);
            *ok = 0;
            return lyric_list_new(1);
        }
        tagged[0] = (uint8_t)('0' + kind);
        memcpy(tagged + 1, ent->d_name, name_len);
        LyricString* entry = lyric_string_from_literal(tagged, (int64_t)(name_len + 1));
        free(tagged);
        lyric_list_push(list, (int64_t)(intptr_t)entry); /* list retains it */
        lyric_release(entry); /* drop this function's local reference */
        errno = 0;
    }
    /* readdir returns NULL both at end-of-stream and on error;
     * a non-zero errno after the loop means the latter. */
    if (errno != 0) {
        lyric_release(list);
        closedir(d);
        *ok = 0;
        return lyric_list_new(1);
    }
    closedir(d);
    *ok = 1;
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
/* ── Process arguments (D-N-015 slice work) ────────────────────────── */

static int          g_lyric_argc = 0;
static char**       g_lyric_argv = NULL;
static LyricList*   g_lyric_args_cached = NULL;

/* In production argv is captured once at process startup and never
 * mutated afterward, so the lyric_args_get cache below never needs
 * invalidating. Unit tests call lyric_args_set more than once per
 * process, though, so drop the cache's own ref here to keep it
 * honest — any refs already handed out by lyric_args_get stay alive
 * on their own until their holders release them. */
void lyric_args_set(int32_t argc, char** argv) {
    g_lyric_argc = argc;
    g_lyric_argv = argv;
    if (g_lyric_args_cached) {
        lyric_release(g_lyric_args_cached);
        g_lyric_args_cached = NULL;
    }
}

/* Retained-ref list of the argv strings captured by lyric_args_set
 * (including argv[0], matching the managed GetCommandLineArgs
 * convention).  An empty list when main never called lyric_args_set.
 *
 * Built once and cached for the process lifetime: `args()` returns
 * `slice[T]`, whose language-level API is non-mutating (§5.2, no
 * in-place mutation), and argv itself never changes after
 * lyric_args_set — so every call can safely hand out an extra ref to
 * the same underlying LyricList instead of rebuilding it.  The cache
 * holds one permanent ref (never released); each call retains and
 * returns it, so the caller's eventual lyric_release just drops back
 * to the cache's own ref. */
LyricList* lyric_args_get(void) {
    if (!g_lyric_args_cached) {
        LyricList* list = lyric_list_new(1);
        for (int i = 0; i < g_lyric_argc; i++) {
            LyricString* s = lyric_string_from_literal(
                (const uint8_t*)g_lyric_argv[i], (int64_t)strlen(g_lyric_argv[i]));
            lyric_list_push(list, (int64_t)(intptr_t)s);
            lyric_release(s);
        }
        g_lyric_args_cached = list;
    }
    lyric_retain(g_lyric_args_cached);
    return g_lyric_args_cached;
}
