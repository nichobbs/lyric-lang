/* lyric_fs_win32.c — the Windows twin of lyric_fs.c (docs/67 G9): file,
 * directory, environment and command-line helpers for Std.File,
 * Std.Directory and Std.Environment over the wide Win32 API.
 *
 * The contract is lyric_fs.c's: every failure is environmental and returns
 * -1/0/NULL, never a panic.  "Follows symlinks" there means the same here
 * for Windows symbolic links and junctions (reparse points): the probes open
 * the target with CreateFileW, which resolves them.
 */
#include "lyric_rt.h"
#include "lyric_win32_internal.h"

#include <shellapi.h>
#include <stdlib.h>
#include <string.h>

/* ── Path probes ───────────────────────────────────────────────────── */

typedef struct {
    DWORD attrs;
    FILETIME mtime;
} lyric_win32_stat;

/* The attributes and last-write time of what `path` names, following
 * symbolic links and junctions; 0 on success, -1 when it does not resolve. */
static int stat_follow(const char* path, lyric_win32_stat* st) {
    wchar_t* w = lyric_win32_path(path);
    if (!w) return -1;
    /* FILE_FLAG_BACKUP_SEMANTICS lets CreateFileW open a directory; no
     * access rights are requested, so nothing is locked or denied. */
    HANDLE h = CreateFileW(w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return -1;
    BY_HANDLE_FILE_INFORMATION info;
    BOOL ok = GetFileInformationByHandle(h, &info);
    CloseHandle(h);
    if (!ok) return -1;
    st->attrs = info.dwFileAttributes;
    st->mtime = info.ftLastWriteTime;
    return 0;
}

/* The link's own attributes, not its target's (INVALID_FILE_ATTRIBUTES when
 * the path does not exist). */
static DWORD attrs_nofollow(const char* path) {
    wchar_t* w = lyric_win32_path(path);
    if (!w) return INVALID_FILE_ATTRIBUTES;
    DWORD a = GetFileAttributesW(w);
    free(w);
    return a;
}

static int is_dir_attrs(DWORD a) {
    return (a & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

/* A regular file, for lyric_file_exists and the typed listing: anything that
 * is not a directory or a device. */
static int is_reg_attrs(DWORD a) {
    return (a & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE)) == 0;
}

/* ── Files ─────────────────────────────────────────────────────────── */

int32_t lyric_file_open(const char* path, int32_t flags, int32_t mode) {
    return lyric_open_fd(path, flags, mode);
}

int32_t lyric_file_close(int32_t fd) {
    return lyric_close_fd(fd) == 0 ? 0 : -1;
}

/* Opens `path` for one whole-file operation. */
static HANDLE open_whole(const char* path, DWORD access, DWORD disposition) {
    wchar_t* w = lyric_win32_path(path);
    if (!w) return INVALID_HANDLE_VALUE;
    HANDLE h = CreateFileW(w, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, disposition,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    free(w);
    return h;
}

/* The whole file at `path` in a fresh malloc'd buffer the caller frees, its
 * length through *out_len; NULL on any failure (see lyric_fs.c). */
static uint8_t* read_file_to_buf(const char* path, int64_t* out_len) {
    HANDLE h = open_whole(path, GENERIC_READ, OPEN_EXISTING);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    int64_t cap = 4096;
    LARGE_INTEGER size;
    if (GetFileType(h) == FILE_TYPE_DISK && GetFileSizeEx(h, &size) && size.QuadPart > 0) {
        cap = size.QuadPart;
    }
    uint8_t* buf = (uint8_t*)malloc((size_t)cap);
    if (!buf) {
        CloseHandle(h);
        return NULL;
    }
    int64_t len = 0;
    for (;;) {
        if (len == cap) {
            if (cap > INT64_MAX / 2) {
                free(buf);
                CloseHandle(h);
                return NULL;
            }
            cap *= 2;
            uint8_t* nb = (uint8_t*)realloc(buf, (size_t)cap);
            if (!nb) {
                free(buf);
                CloseHandle(h);
                return NULL;
            }
            buf = nb;
        }
        int64_t want = cap - len;
        DWORD chunk = want > 0x40000000 ? 0x40000000UL : (DWORD)want;
        DWORD got = 0;
        if (!ReadFile(h, buf + len, chunk, &got, NULL)) {
            if (GetLastError() == ERROR_BROKEN_PIPE) break; /* a pipe's writer closed: end of data */
            free(buf);
            CloseHandle(h);
            return NULL;
        }
        if (got == 0) break; /* EOF */
        len += got;
    }
    CloseHandle(h);
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

LyricList* lyric_file_read_bytes(const char* path, int64_t* ok) {
    int64_t len = 0;
    uint8_t* buf = read_file_to_buf(path, &len);
    if (!buf) {
        *ok = 0;
        return lyric_list_new(0);
    }
    LyricList* list = lyric_list_from_bytes(buf, len);
    free(buf);
    *ok = 1;
    return list;
}

/* Writes `len` bytes to `path`, creating or truncating it (append != 0
 * appends).  0 on success, -1 on failure. */
static int32_t write_whole(const char* path, const uint8_t* p, int64_t len, int32_t append) {
    HANDLE h = open_whole(path, append ? FILE_APPEND_DATA : GENERIC_WRITE, append ? OPEN_ALWAYS : CREATE_ALWAYS);
    if (h == INVALID_HANDLE_VALUE) return -1;
    int64_t off = 0;
    while (off < len) {
        int64_t left = len - off;
        DWORD chunk = left > 0x40000000 ? 0x40000000UL : (DWORD)left;
        DWORD wrote = 0;
        if (!WriteFile(h, p + off, chunk, &wrote, NULL) || wrote == 0) {
            CloseHandle(h);
            return -1;
        }
        off += wrote;
    }
    return CloseHandle(h) ? 0 : -1;
}

int32_t lyric_file_write_all(const char* path, LyricString* data, int32_t append) {
    int64_t len = data ? data->len : 0;
    return write_whole(path, len > 0 ? LYRIC_STRING_DATA(data) : NULL, len, append);
}

int32_t lyric_file_write_bytes(const char* path, LyricList* data, int32_t append) {
    int64_t len = data ? data->len : 0;
    uint8_t* buf = NULL;
    if (len > 0) {
        buf = (uint8_t*)malloc((size_t)len);
        if (!buf) return -1;
        for (int64_t i = 0; i < len; i++) buf[i] = (uint8_t)data->data[i];
    }
    int32_t rc = write_whole(path, buf, len, append);
    free(buf);
    return rc;
}

/* A symbolic link or junction to a directory is itself a directory entry on
 * Windows, removed with RemoveDirectoryW (which removes only the link); a
 * recursive delete reaches it through lyric_path_is_dir_nofollow == 0 and
 * deletes it here, never descending into its target. */
int32_t lyric_file_delete(const char* path) {
    DWORD a = attrs_nofollow(path);
    if (a != INVALID_FILE_ATTRIBUTES && is_dir_attrs(a) && (a & FILE_ATTRIBUTE_REPARSE_POINT)) {
        return lyric_rmdir(path) == 0 ? 0 : -1;
    }
    return lyric_unlink(path) == 0 ? 0 : -1;
}

/* POSIX rename replaces an existing destination file; MoveFileExW does so
 * only when asked. */
int32_t lyric_file_rename(const char* old_path, const char* new_path) {
    wchar_t* wo = lyric_win32_path(old_path);
    wchar_t* wn = lyric_win32_path(new_path);
    BOOL ok = wo && wn && MoveFileExW(wo, wn, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED);
    free(wo);
    free(wn);
    return ok ? 0 : -1;
}

int32_t lyric_file_exists(const char* path) {
    lyric_win32_stat st;
    if (stat_follow(path, &st) != 0) return 0;
    return is_reg_attrs(st.attrs) ? 1 : 0;
}

int32_t lyric_file_mtime_epoch_nanos_ok(const char* path, int64_t* out_nanos) {
    lyric_win32_stat st;
    if (stat_follow(path, &st) != 0) return -1;
    /* A FILETIME spans 1601..30828; the nanosecond Instant only 1677..2262. */
    int64_t ticks = (int64_t)(((uint64_t)st.mtime.dwHighDateTime << 32) | st.mtime.dwLowDateTime);
    int64_t unix_ticks = ticks - 116444736000000000LL;
    if (unix_ticks > INT64_MAX / 100 || unix_ticks < INT64_MIN / 100) return -1;
    *out_nanos = lyric_win32_filetime_to_unix_nanos(st.mtime);
    return 0;
}

/* ── Directories ───────────────────────────────────────────────────── */

int32_t lyric_dir_create(const char* path) {
    return lyric_mkdir(path, 0755) == 0 ? 0 : -1;
}

static int is_sep(char c) {
    return c == '/' || c == '\\';
}

static int32_t dir_is_existing(const char* path) {
    lyric_win32_stat st;
    return stat_follow(path, &st) == 0 && is_dir_attrs(st.attrs) ? 0 : -1;
}

/* lyric_fs.c's walk-up over both separators: the full path is tried first,
 * and only a missing parent walks up to create it.  A drive root ("C:\") or
 * a UNC share is never created, only found to exist. */
static int32_t dir_create_all_buf(char* buf, size_t len) {
    wchar_t* w = lyric_win32_path(buf);
    if (!w) return -1;
    BOOL ok = CreateDirectoryW(w, NULL);
    DWORD err = ok ? 0 : GetLastError();
    free(w);
    if (ok) return 0;
    if (err == ERROR_ALREADY_EXISTS || err == ERROR_ACCESS_DENIED) return dir_is_existing(buf);
    if (err != ERROR_PATH_NOT_FOUND) return -1;
    size_t i = len;
    while (i > 0 && is_sep(buf[i - 1])) i--;  /* trailing separators */
    while (i > 0 && !is_sep(buf[i - 1])) i--; /* last component */
    while (i > 0 && is_sep(buf[i - 1])) i--;  /* separator run */
    if (i == 0) return -1;
    char saved = buf[i];
    buf[i] = '\0';
    int32_t rc = dir_create_all_buf(buf, i);
    buf[i] = saved;
    if (rc != 0) return -1;
    w = lyric_win32_path(buf);
    if (!w) return -1;
    ok = CreateDirectoryW(w, NULL);
    err = ok ? 0 : GetLastError();
    free(w);
    if (ok) return 0;
    if (err == ERROR_ALREADY_EXISTS) return dir_is_existing(buf);
    return -1;
}

int32_t lyric_dir_create_all(const char* path) {
    size_t len = strlen(path);
    if (len == 0) return -1;
    char* buf = (char*)malloc(len + 1);
    if (!buf) return -1;
    memcpy(buf, path, len + 1);
    int32_t rc = dir_create_all_buf(buf, len);
    free(buf);
    return rc;
}

int32_t lyric_dir_remove(const char* path) {
    return lyric_rmdir(path) == 0 ? 0 : -1;
}

int32_t lyric_dir_exists(const char* path) {
    lyric_win32_stat st;
    if (stat_follow(path, &st) != 0) return 0;
    return is_dir_attrs(st.attrs) ? 1 : 0;
}

/* A directory that is not a link: a symbolic link or junction to a
 * directory reports 0, so a recursive delete removes the link and never
 * descends into its target (see lyric_file_delete). */
int32_t lyric_path_is_dir_nofollow(const char* path) {
    DWORD a = attrs_nofollow(path);
    if (a == INVALID_FILE_ATTRIBUTES) return 0;
    return is_dir_attrs(a) && !(a & FILE_ATTRIBUTE_REPARSE_POINT) ? 1 : 0;
}

/* Calls `each(name, name_len, data, ctx)` for every entry of `path` except
 * "." and ".."; 0 when the listing completed, -1 when the directory cannot
 * be read or `each` returns non-zero. */
typedef int (*dir_entry_fn)(const char* name, int64_t name_len, const WIN32_FIND_DATAW* data, void* ctx);

static int32_t for_each_entry(const char* path, dir_entry_fn each, void* ctx) {
    size_t n = strlen(path);
    char* pattern = (char*)malloc(n + 3);
    if (!pattern) return -1;
    memcpy(pattern, path, n);
    size_t m = n;
    if (m > 0 && !is_sep(pattern[m - 1])) pattern[m++] = '\\';
    pattern[m++] = '*';
    pattern[m] = '\0';
    wchar_t* w = lyric_win32_path(pattern);
    free(pattern);
    if (!w) return -1;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileExW(w, FindExInfoBasic, &fd, FindExSearchNameMatch, NULL, FIND_FIRST_EX_LARGE_FETCH);
    free(w);
    if (h == INVALID_HANDLE_VALUE) {
        /* An empty directory still lists "." and ".."; no match at all
         * means the directory does not exist or cannot be read. */
        return -1;
    }
    int32_t rc = 0;
    do {
        if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
        int64_t name_len = 0;
        char* name = lyric_win32_utf8(fd.cFileName, -1, &name_len);
        if (!name) {
            rc = -1;
            break;
        }
        int stop = each(name, name_len, &fd, ctx);
        free(name);
        if (stop) {
            rc = -1;
            break;
        }
    } while (FindNextFileW(h, &fd));
    if (rc == 0 && GetLastError() != ERROR_NO_MORE_FILES) rc = -1;
    FindClose(h);
    return rc;
}

static int push_name(const char* name, int64_t name_len, const WIN32_FIND_DATAW* data, void* ctx) {
    (void)data;
    LyricString* s = lyric_string_from_literal((const uint8_t*)name, name_len);
    lyric_list_push((LyricList*)ctx, (int64_t)(intptr_t)s); /* list retains it */
    lyric_release(s);
    return 0;
}

LyricList* lyric_dir_list(const char* path) {
    LyricList* list = lyric_list_new(1);
    if (for_each_entry(path, push_name, list) != 0) {
        lyric_release(list);
        return NULL;
    }
    return list;
}

LyricList* lyric_dir_list2(const char* path, int64_t* ok) {
    LyricList* l = lyric_dir_list(path);
    if (!l) {
        *ok = 0;
        return lyric_list_new(1);
    }
    *ok = 1;
    return l;
}

typedef struct {
    LyricList* list;
    const char* dir;
    size_t dir_len;
} typed_ctx;

/* lyric_fs.c's classify_dirent: the find data's attributes classify an
 * ordinary entry with no further call; a link is classified by its target,
 * like the following probes. */
static int push_typed(const char* name, int64_t name_len, const WIN32_FIND_DATAW* data, void* vctx) {
    typed_ctx* ctx = (typed_ctx*)vctx;
    int32_t kind;
    if (data->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        char* full = (char*)malloc(ctx->dir_len + 1 + (size_t)name_len + 1);
        if (!full) return 1;
        memcpy(full, ctx->dir, ctx->dir_len);
        full[ctx->dir_len] = '\\';
        memcpy(full + ctx->dir_len + 1, name, (size_t)name_len + 1);
        lyric_win32_stat st;
        if (stat_follow(full, &st) != 0) {
            kind = LYRIC_DIRENT_OTHER;
        } else {
            kind = is_dir_attrs(st.attrs) ? LYRIC_DIRENT_DIR : is_reg_attrs(st.attrs) ? LYRIC_DIRENT_REG
                                                                                     : LYRIC_DIRENT_OTHER;
        }
        free(full);
    } else {
        kind = is_dir_attrs(data->dwFileAttributes) ? LYRIC_DIRENT_DIR
             : is_reg_attrs(data->dwFileAttributes) ? LYRIC_DIRENT_REG
                                                    : LYRIC_DIRENT_OTHER;
    }
    uint8_t* tagged = (uint8_t*)malloc((size_t)name_len + 1);
    if (!tagged) return 1;
    tagged[0] = (uint8_t)('0' + kind);
    memcpy(tagged + 1, name, (size_t)name_len);
    LyricString* entry = lyric_string_from_literal(tagged, name_len + 1);
    free(tagged);
    lyric_list_push(ctx->list, (int64_t)(intptr_t)entry);
    lyric_release(entry);
    return 0;
}

LyricList* lyric_dir_list_typed(const char* path, int64_t* ok) {
    typed_ctx ctx;
    ctx.list = lyric_list_new(1);
    ctx.dir = path;
    ctx.dir_len = strlen(path);
    while (ctx.dir_len > 0 && is_sep(path[ctx.dir_len - 1])) ctx.dir_len--;
    if (for_each_entry(path, push_typed, &ctx) != 0) {
        lyric_release(ctx.list);
        *ok = 0;
        return lyric_list_new(1);
    }
    *ok = 1;
    return ctx.list;
}

/* ── Environment ───────────────────────────────────────────────────── */

/* The Win32 process environment, which child processes inherit; the CRT's
 * narrow copy (getenv) is in the ANSI code page and is not kept in step
 * with SetEnvironmentVariableW. */
LyricString* lyric_env_get(const char* name) {
    wchar_t* wname = lyric_win32_wide(name);
    if (!wname) return NULL;
    DWORD cap = 256;
    wchar_t* buf = NULL;
    for (;;) {
        wchar_t* nb = (wchar_t*)realloc(buf, (size_t)cap * sizeof(wchar_t));
        if (!nb) {
            free(buf);
            free(wname);
            return NULL;
        }
        buf = nb;
        SetLastError(ERROR_SUCCESS);
        DWORD n = GetEnvironmentVariableW(wname, buf, cap);
        if (n == 0 && GetLastError() == ERROR_ENVVAR_NOT_FOUND) {
            free(buf);
            free(wname);
            return NULL;
        }
        if (n < cap) {
            free(wname);
            int64_t len = 0;
            char* utf8 = lyric_win32_utf8(buf, (int64_t)n, &len);
            free(buf);
            if (!utf8) return NULL;
            LyricString* s = lyric_string_from_literal((const uint8_t*)utf8, len);
            free(utf8);
            return s;
        }
        cap = n; /* n is the size needed, including the NUL */
    }
}

int32_t lyric_env_get_ok(const char* name, LyricString** out) {
    LyricString* s = lyric_env_get(name);
    if (!s) return -1;
    *out = s;
    return 0;
}

int32_t lyric_env_set(const char* name, const char* value) {
    wchar_t* wn = lyric_win32_wide(name);
    wchar_t* wv = lyric_win32_wide(value);
    BOOL ok = wn && wv && wn[0] != L'\0' && wcschr(wn, L'=') == NULL && SetEnvironmentVariableW(wn, wv);
    free(wn);
    free(wv);
    return ok ? 0 : -1;
}

int32_t lyric_env_is_windows(void) {
    return 1;
}

LyricString* lyric_env_cwd(void) {
    DWORD need = GetCurrentDirectoryW(0, NULL);
    if (need == 0) return NULL;
    wchar_t* buf = (wchar_t*)malloc((size_t)need * sizeof(wchar_t));
    if (!buf) return NULL;
    DWORD n = GetCurrentDirectoryW(need, buf);
    if (n == 0 || n >= need) {
        free(buf);
        return NULL;
    }
    int64_t len = 0;
    char* utf8 = lyric_win32_utf8(buf, (int64_t)n, &len);
    free(buf);
    if (!utf8) return NULL;
    LyricString* s = lyric_string_from_literal((const uint8_t*)utf8, len);
    free(utf8);
    return s;
}

int32_t lyric_env_cwd_ok(LyricString** out) {
    LyricString* s = lyric_env_cwd();
    if (!s) return -1;
    *out = s;
    return 0;
}

/* The directory holding the running executable, with its trailing
 * separator (.NET's AppContext.BaseDirectory contract). */
int32_t lyric_env_app_base_directory_ok(LyricString** out) {
    DWORD cap = MAX_PATH;
    wchar_t* buf = NULL;
    DWORD n;
    for (;;) {
        wchar_t* nb = (wchar_t*)realloc(buf, (size_t)cap * sizeof(wchar_t));
        if (!nb) {
            free(buf);
            return -1;
        }
        buf = nb;
        n = GetModuleFileNameW(NULL, buf, cap);
        if (n == 0) {
            free(buf);
            return -1;
        }
        if (n < cap) break; /* not truncated */
        if (cap > 32768) {
            free(buf);
            return -1;
        }
        cap *= 2;
    }
    DWORD dir_len = n;
    while (dir_len > 0 && buf[dir_len - 1] != L'\\' && buf[dir_len - 1] != L'/') dir_len--;
    if (dir_len == 0) {
        free(buf);
        return -1;
    }
    int64_t len = 0;
    char* utf8 = lyric_win32_utf8(buf, (int64_t)dir_len, &len);
    free(buf);
    if (!utf8) return -1;
    *out = lyric_string_from_literal((const uint8_t*)utf8, len);
    free(utf8);
    return 0;
}

/* ── Process arguments ─────────────────────────────────────────────── */

static int g_lyric_argc = 0;
static char** g_lyric_argv = NULL;
static LyricList* g_lyric_args_cached = NULL;

/* The CRT's own argv (what `main` receives) is in the ANSI code page, so
 * when lyric_args_set is handed that array the arguments are re-read from
 * the UTF-16 command line instead; an argv built by the caller (the unit
 * tests) is taken as UTF-8 as given. */
void lyric_args_set(int32_t argc, char** argv) {
    g_lyric_argc = argc;
    g_lyric_argv = argv;
    if (g_lyric_args_cached) {
        lyric_release(g_lyric_args_cached);
        g_lyric_args_cached = NULL;
    }
}

static void push_arg(LyricList* list, const char* s, int64_t len) {
    LyricString* str = lyric_string_from_literal((const uint8_t*)s, len);
    lyric_list_push(list, (int64_t)(intptr_t)str);
    lyric_release(str);
}

LyricList* lyric_args_get(void) {
    if (!g_lyric_args_cached) {
        LyricList* list = lyric_list_new(1);
        int wide_done = 0;
        if (g_lyric_argv != NULL && g_lyric_argv == __argv) {
            int wargc = 0;
            wchar_t** wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
            if (wargv) {
                for (int i = 0; i < wargc; i++) {
                    int64_t len = 0;
                    char* utf8 = lyric_win32_utf8(wargv[i], -1, &len);
                    push_arg(list, utf8 ? utf8 : "", utf8 ? len : 0);
                    free(utf8);
                }
                LocalFree(wargv);
                wide_done = 1;
            }
        }
        if (!wide_done) {
            for (int i = 0; i < g_lyric_argc; i++) {
                push_arg(list, g_lyric_argv[i], (int64_t)strlen(g_lyric_argv[i]));
            }
        }
        g_lyric_args_cached = list;
    }
    lyric_retain(g_lyric_args_cached);
    return g_lyric_args_cached;
}
