/* lyric_process_win32.c — the Windows twin of lyric_process.c (docs/67 G9,
 * #8433): subprocess execution with stdout/stderr capture, the nonblocking
 * capture op behind the async process leaf, and long-lived piped children.
 *
 * Each entry point keeps the POSIX twin's contract; the differences are in
 * how it is met:
 *
 *   - The program is resolved here (a path with a separator as given, a bare
 *     name through PATH), with ".exe" tried first for a name without an
 *     extension, and handed to CreateProcessW as lpApplicationName, so the
 *     OS performs no search of its own (no current-directory lookup).  No
 *     shell is ever involved: a batch file (.bat/.cmd), which Windows would
 *     run through cmd.exe and re-parse its arguments, is refused with
 *     ENOEXEC; run `cmd.exe /c` explicitly to opt in to that.
 *   - Arguments are quoted with the rules CommandLineToArgvW and the C
 *     runtime use to split a command line, so the child receives exactly
 *     the argv the caller passed.
 *   - The parent's pipe ends are overlapped named pipes (anonymous pipes
 *     cannot be waited on), and the child's ends are passed through
 *     PROC_THREAD_ATTRIBUTE_HANDLE_LIST, so a concurrent spawn on another
 *     thread never inherits them (the POSIX twin's O_CLOEXEC).
 *   - Captured and piped children start in a Job Object, so a deadline or an
 *     explicit kill ends the child's whole tree (the POSIX twin's process
 *     group, D-N-025), and in a new process group, so a Ctrl+C in the
 *     parent's console does not reach them.  A killed tree exits with
 *     status 137, the 128 + SIGKILL the POSIX twin reports.
 *   - A child's own exit status is reported as is; a crash shows up as its
 *     NTSTATUS (for example 0xC0000005, as a negative 32-bit value).
 */
#include "lyric_rt.h"
#include "lyric_win32_internal.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* The exit status a killed child reports: 128 + SIGKILL, as on POSIX. */
#define LYRIC_KILLED_STATUS 137

/* Size of each pipe's kernel buffer, and of one overlapped read. */
#define LYRIC_PIPE_BUFFER 65536
#define LYRIC_READ_CHUNK 4096
/* Largest single overlapped write of stdin content. */
#define LYRIC_WRITE_CHUNK 65536

/* errno of the most recent failed start on this thread (0 when unknown). */
static _Thread_local int32_t last_spawn_errno = 0;

/* ── Growable byte buffer ──────────────────────────────────────────── */

typedef struct {
    uint8_t* data;
    int64_t len;
    int64_t cap;
} ProcBuf;

static void procbuf_append(ProcBuf* b, const uint8_t* chunk, int64_t n) {
    if (b->len + n > b->cap) {
        int64_t newcap = b->cap < 4096 ? 4096 : b->cap;
        while (newcap < b->len + n) {
            if (newcap > INT64_MAX / 2)
                lyric_panic_msg("process output exceeds capacity", "lyric_process_win32.c", __LINE__);
            newcap *= 2;
        }
        uint8_t* nd = (uint8_t*)realloc(b->data, (size_t)newcap);
        if (!nd) lyric_panic_msg("OOM capturing process output", "lyric_process_win32.c", __LINE__);
        b->data = nd;
        b->cap = newcap;
    }
    memcpy(b->data + b->len, chunk, (size_t)n);
    b->len += n;
}

/* ── Overlapped pipe ends ──────────────────────────────────────────── */

/* The parent's end of one pipe, with at most one overlapped operation in
 * flight.  For a read end, `buf` receives the bytes; for a write end, the
 * operation writes from caller-owned memory that must stay alive until it
 * completes. */
typedef struct {
    HANDLE h; /* INVALID_HANDLE_VALUE once closed */
    OVERLAPPED ov;
    int pending;
    uint8_t buf[LYRIC_READ_CHUNK];
} WinPipe;

/* Outcome of collecting an overlapped operation. */
enum { PIPE_PENDING = 0, PIPE_DONE = 1, PIPE_EOF = 2 };

static void winpipe_init(WinPipe* p) {
    memset(p, 0, sizeof *p);
    p->h = INVALID_HANDLE_VALUE;
}

static int winpipe_open(const WinPipe* p) {
    return p->h != INVALID_HANDLE_VALUE;
}

/* Cancels any operation in flight, waits for the cancellation (the kernel
 * owns `ov` and the buffer until then) and closes the end. */
static void winpipe_close(WinPipe* p) {
    if (!winpipe_open(p)) return;
    if (p->pending) {
        DWORD n = 0;
        CancelIoEx(p->h, &p->ov);
        GetOverlappedResult(p->h, &p->ov, &n, TRUE);
        p->pending = 0;
    }
    CloseHandle(p->h);
    p->h = INVALID_HANDLE_VALUE;
    if (p->ov.hEvent) {
        CloseHandle(p->ov.hEvent);
        p->ov.hEvent = NULL;
    }
}

/* Collects the operation in flight, waiting up to `wait_ms` (INFINITE
 * allowed).  PIPE_DONE stores the byte count; PIPE_EOF means the other end
 * is gone (or the pipe failed), and no operation is in flight any more. */
static int winpipe_collect(WinPipe* p, DWORD wait_ms, DWORD* out_n) {
    *out_n = 0;
    if (!p->pending) return PIPE_DONE;
    if (wait_ms != 0 && WaitForSingleObject(p->ov.hEvent, wait_ms) == WAIT_TIMEOUT) return PIPE_PENDING;
    DWORD n = 0;
    if (GetOverlappedResult(p->h, &p->ov, &n, FALSE)) {
        p->pending = 0;
        *out_n = n;
        return PIPE_DONE;
    }
    if (GetLastError() == ERROR_IO_INCOMPLETE) return PIPE_PENDING;
    p->pending = 0;
    return PIPE_EOF;
}

/* Issues one overlapped read into `buf` unless one is already in flight.
 * Returns PIPE_EOF when the write end is already gone. */
static int winpipe_read_start(WinPipe* p) {
    if (p->pending) return PIPE_PENDING;
    ResetEvent(p->ov.hEvent);
    if (ReadFile(p->h, p->buf, sizeof p->buf, NULL, &p->ov) || GetLastError() == ERROR_IO_PENDING) {
        p->pending = 1;
        return PIPE_PENDING;
    }
    return PIPE_EOF;
}

/* Issues one overlapped write of `n` bytes at `data`. */
static int winpipe_write_start(WinPipe* p, const uint8_t* data, DWORD n) {
    if (p->pending) return PIPE_PENDING;
    ResetEvent(p->ov.hEvent);
    if (WriteFile(p->h, data, n, NULL, &p->ov) || GetLastError() == ERROR_IO_PENDING) {
        p->pending = 1;
        return PIPE_PENDING;
    }
    return PIPE_EOF;
}

/* Drains whatever the pipe holds into `buf` without waiting: completes the
 * read in flight if it has finished and keeps issuing reads while they
 * complete at once.  Closes the end at end of stream. */
static void winpipe_pump_read(WinPipe* p, ProcBuf* buf) {
    while (winpipe_open(p)) {
        if (!p->pending && winpipe_read_start(p) == PIPE_EOF) {
            winpipe_close(p);
            return;
        }
        DWORD n = 0;
        int r = winpipe_collect(p, 0, &n);
        if (r == PIPE_PENDING) return;
        if (r == PIPE_EOF) {
            winpipe_close(p);
            return;
        }
        if (n > 0) procbuf_append(buf, p->buf, n);
    }
}

static volatile LONG64 pipe_serial = 0;

/* A connected pipe: `parent` is the overlapped server end the runtime keeps
 * (inbound when the parent reads, outbound when it writes); `*child` is the
 * synchronous, inheritable client end the child receives.  0 on success. */
static int make_pipe(WinPipe* parent, HANDLE* child, int parent_reads) {
    winpipe_init(parent);
    *child = INVALID_HANDLE_VALUE;
    wchar_t name[96];
    HANDLE server = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 16 && server == INVALID_HANDLE_VALUE; attempt++) {
        LONG64 serial = InterlockedIncrement64(&pipe_serial);
        _snwprintf(name, sizeof name / sizeof name[0], L"\\\\.\\pipe\\lyric-rt-%lu-%lld",
                   (unsigned long)GetCurrentProcessId(), (long long)serial);
        name[sizeof name / sizeof name[0] - 1] = L'\0';
        server = CreateNamedPipeW(name,
                                  (parent_reads ? PIPE_ACCESS_INBOUND : PIPE_ACCESS_OUTBOUND) |
                                      FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                                  PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                  1, LYRIC_PIPE_BUFFER, LYRIC_PIPE_BUFFER, 0, NULL);
        if (server == INVALID_HANDLE_VALUE && GetLastError() != ERROR_ACCESS_DENIED &&
            GetLastError() != ERROR_PIPE_BUSY) {
            break; /* not a name collision */
        }
    }
    if (server == INVALID_HANDLE_VALUE) {
        errno = lyric_win32_errno(GetLastError());
        return -1;
    }
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof sa;
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;
    HANDLE client = CreateFileW(name, parent_reads ? GENERIC_WRITE : GENERIC_READ, 0, &sa, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, NULL);
    if (client == INVALID_HANDLE_VALUE) {
        errno = lyric_win32_errno(GetLastError());
        CloseHandle(server);
        return -1;
    }
    HANDLE ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ev) {
        errno = lyric_win32_errno(GetLastError());
        CloseHandle(client);
        CloseHandle(server);
        return -1;
    }
    parent->h = server;
    parent->ov.hEvent = ev;
    *child = client;
    return 0;
}

static void close_child_handle(HANDLE* h) {
    if (*h != INVALID_HANDLE_VALUE && *h != NULL) CloseHandle(*h);
    *h = INVALID_HANDLE_VALUE;
}

/* An inheritable duplicate of this process's standard handle `which`, or
 * INVALID_HANDLE_VALUE when it has none (a GUI process, a closed stream). */
static HANDLE inheritable_std_handle(DWORD which) {
    HANDLE h = GetStdHandle(which);
    if (h == NULL || h == INVALID_HANDLE_VALUE) return INVALID_HANDLE_VALUE;
    HANDLE dup = INVALID_HANDLE_VALUE;
    if (!DuplicateHandle(GetCurrentProcess(), h, GetCurrentProcess(), &dup, 0, TRUE, DUPLICATE_SAME_ACCESS)) {
        return INVALID_HANDLE_VALUE;
    }
    return dup;
}

/* ── Program resolution and the command line ───────────────────────── */

static int has_separator(const char* s) {
    for (; *s; s++) {
        if (*s == '/' || *s == '\\' || *s == ':') return 1;
    }
    return 0;
}

/* True when the last path component of `w` has an extension. */
static int has_extension(const wchar_t* w) {
    const wchar_t* base = w;
    for (const wchar_t* c = w; *c; c++) {
        if (*c == L'\\' || *c == L'/' || *c == L':') base = c + 1;
    }
    return wcschr(base, L'.') != NULL;
}

static int ends_with_ci(const wchar_t* w, const wchar_t* suffix) {
    size_t n = wcslen(w);
    size_t m = wcslen(suffix);
    return n >= m && _wcsicmp(w + n - m, suffix) == 0;
}

static int is_regular_file(const wchar_t* w) {
    DWORD a = GetFileAttributesW(w);
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

/* Returns a malloc'd copy of `base` (+ ".exe" when `with_exe`) when that
 * names a regular file, NULL otherwise. */
static wchar_t* try_candidate(const wchar_t* base, int with_exe) {
    size_t n = wcslen(base);
    wchar_t* w = (wchar_t*)malloc((n + 5) * sizeof(wchar_t));
    if (!w) return NULL;
    memcpy(w, base, n * sizeof(wchar_t));
    if (with_exe) {
        memcpy(w + n, L".exe", 5 * sizeof(wchar_t));
    } else {
        w[n] = L'\0';
    }
    if (is_regular_file(w)) return w;
    free(w);
    return NULL;
}

/* `base` itself when it has an extension; otherwise `base`.exe, then
 * `base` as is (CreateProcessW runs an extensionless image too). */
static wchar_t* resolve_candidate(const wchar_t* base) {
    if (has_extension(base)) return try_candidate(base, 0);
    wchar_t* w = try_candidate(base, 1);
    return w ? w : try_candidate(base, 0);
}

/* The full path CreateProcessW should run for `path`, or NULL with errno
 * set (ENOENT when nothing matches, EINVAL for text that is not valid
 * UTF-8, ENOEXEC for a batch file). */
static wchar_t* resolve_program(const char* path) {
    if (!path || !*path) {
        errno = ENOENT;
        return NULL;
    }
    wchar_t* wpath = lyric_win32_wide(path);
    if (!wpath) {
        errno = EINVAL;
        return NULL;
    }
    wchar_t* found = NULL;
    if (has_separator(path)) {
        found = resolve_candidate(wpath);
    } else {
        DWORD need = GetEnvironmentVariableW(L"PATH", NULL, 0);
        wchar_t* env = need ? (wchar_t*)malloc((size_t)need * sizeof(wchar_t)) : NULL;
        if (env && GetEnvironmentVariableW(L"PATH", env, need) < need) {
            size_t name_len = wcslen(wpath);
            wchar_t* dir = env;
            while (!found && dir && *dir) {
                wchar_t* next = wcschr(dir, L';');
                if (next) *next++ = L'\0';
                size_t dl = wcslen(dir);
                if (dl >= 2 && dir[0] == L'"' && dir[dl - 1] == L'"') {
                    dir[dl - 1] = L'\0';
                    dir++;
                    dl -= 2;
                }
                if (dl > 0) {
                    wchar_t* joined = (wchar_t*)malloc((dl + 1 + name_len + 1) * sizeof(wchar_t));
                    if (joined) {
                        memcpy(joined, dir, dl * sizeof(wchar_t));
                        size_t at = dl;
                        if (dir[dl - 1] != L'\\' && dir[dl - 1] != L'/') joined[at++] = L'\\';
                        memcpy(joined + at, wpath, (name_len + 1) * sizeof(wchar_t));
                        found = resolve_candidate(joined);
                        free(joined);
                    }
                }
                dir = next;
            }
        }
        free(env);
    }
    free(wpath);
    if (!found) {
        errno = ENOENT;
        return NULL;
    }
    if (ends_with_ci(found, L".bat") || ends_with_ci(found, L".cmd")) {
        free(found);
        errno = ENOEXEC;
        return NULL;
    }
    return found;
}

typedef struct {
    char* data;
    size_t len;
    size_t cap;
} CmdBuf;

static int cmd_push(CmdBuf* b, const char* s, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n + 1) cap *= 2;
        char* d = (char*)realloc(b->data, cap);
        if (!d) return -1;
        b->data = d;
        b->cap = cap;
    }
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
    return 0;
}

static int cmd_push_backslashes(CmdBuf* b, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (cmd_push(b, "\\", 1) != 0) return -1;
    }
    return 0;
}

/* Appends `arg` quoted so CommandLineToArgvW (and the C runtime's argv
 * parser) yields it back unchanged: an argument with no space, tab, newline
 * or quote is copied as is; otherwise it is wrapped in quotes, each quote is
 * preceded by a backslash, and the backslashes that come before a quote or
 * the closing quote are doubled. */
static int cmd_push_arg(CmdBuf* b, const char* arg, size_t n) {
    int plain = n > 0;
    for (size_t i = 0; i < n && plain; i++) {
        char c = arg[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '"') plain = 0;
    }
    if (plain) return cmd_push(b, arg, n);
    if (cmd_push(b, "\"", 1) != 0) return -1;
    size_t i = 0;
    for (;;) {
        size_t slashes = 0;
        while (i < n && arg[i] == '\\') {
            slashes++;
            i++;
        }
        if (i == n) {
            if (cmd_push_backslashes(b, slashes * 2) != 0) return -1;
            break;
        }
        if (arg[i] == '"') {
            if (cmd_push_backslashes(b, slashes * 2 + 1) != 0 || cmd_push(b, "\"", 1) != 0) return -1;
        } else {
            if (cmd_push_backslashes(b, slashes) != 0 || cmd_push(b, arg + i, 1) != 0) return -1;
        }
        i++;
    }
    return cmd_push(b, "\"", 1);
}

/* The UTF-16 command line for `path` and `args`, or NULL with errno set:
 * EINVAL for a NUL byte or text that is not valid UTF-8, E2BIG past the
 * 32,767-character limit, ENOMEM.  argv[0] is `path` as the caller gave it,
 * quoted (a Windows path cannot contain a quote). */
static wchar_t* build_command_line(const char* path, LyricList* args) {
    if (strchr(path, '"') != NULL) {
        errno = EINVAL;
        return NULL;
    }
    CmdBuf b = {NULL, 0, 0};
    int failed = cmd_push(&b, "\"", 1) != 0 || cmd_push(&b, path, strlen(path)) != 0 || cmd_push(&b, "\"", 1) != 0;
    int64_t nargs = args ? lyric_list_len(args) : 0;
    for (int64_t i = 0; i < nargs && !failed; i++) {
        LyricString* s = (LyricString*)(intptr_t)lyric_list_get(args, i);
        const char* data = (const char*)LYRIC_STRING_DATA(s);
        size_t len = (size_t)lyric_string_len(s);
        if (memchr(data, '\0', len) != NULL) {
            free(b.data);
            errno = EINVAL;
            return NULL;
        }
        failed = cmd_push(&b, " ", 1) != 0 || cmd_push_arg(&b, data, len) != 0;
    }
    if (failed) {
        free(b.data);
        errno = ENOMEM;
        return NULL;
    }
    wchar_t* w = lyric_win32_wide(b.data);
    free(b.data);
    if (!w) {
        errno = EINVAL;
        return NULL;
    }
    if (wcslen(w) >= 32767) {
        free(w);
        errno = E2BIG;
        return NULL;
    }
    return w;
}

/* ── Starting a child ──────────────────────────────────────────────── */

typedef struct {
    HANDLE process;
    HANDLE job; /* NULL when the child could not be placed in a job */
} WinChild;

static void child_init(WinChild* c) {
    c->process = NULL;
    c->job = NULL;
}

/* Starts `path` with `args`, its standard streams set to `in`, `out` and
 * `err` (INVALID_HANDLE_VALUE for none), which must be inheritable and
 * distinct.  `isolate` puts the child in a new process group and its own
 * Job Object.  0 on success; -1 with last_spawn_errno set otherwise. */
static int spawn_child(const char* path, LyricList* args, HANDLE in, HANDLE out, HANDLE err, int isolate,
                       WinChild* child) {
    child_init(child);
    wchar_t* app = resolve_program(path);
    if (!app) {
        last_spawn_errno = errno;
        return -1;
    }
    wchar_t* cmd = build_command_line(path, args);
    if (!cmd) {
        last_spawn_errno = errno;
        free(app);
        return -1;
    }

    HANDLE list[3];
    DWORD count = 0;
    if (in != INVALID_HANDLE_VALUE) list[count++] = in;
    if (out != INVALID_HANDLE_VALUE) list[count++] = out;
    if (err != INVALID_HANDLE_VALUE) list[count++] = err;

    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
    if (!attrs || !InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size)) {
        last_spawn_errno = ENOMEM;
        free(attrs);
        free(cmd);
        free(app);
        return -1;
    }
    if (count > 0 &&
        !UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, list, count * sizeof(HANDLE), NULL,
                                   NULL)) {
        last_spawn_errno = lyric_win32_errno(GetLastError());
        DeleteProcThreadAttributeList(attrs);
        free(attrs);
        free(cmd);
        free(app);
        return -1;
    }

    STARTUPINFOEXW si;
    memset(&si, 0, sizeof si);
    si.StartupInfo.cb = sizeof si;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in == INVALID_HANDLE_VALUE ? NULL : in;
    si.StartupInfo.hStdOutput = out == INVALID_HANDLE_VALUE ? NULL : out;
    si.StartupInfo.hStdError = err == INVALID_HANDLE_VALUE ? NULL : err;
    si.lpAttributeList = attrs;

    DWORD flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;
    if (isolate) flags |= CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED;
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof pi);
    BOOL ok = CreateProcessW(app, cmd, NULL, NULL, count > 0 ? TRUE : FALSE, flags, NULL, NULL, &si.StartupInfo, &pi);
    DWORD create_err = ok ? 0 : GetLastError();
    DeleteProcThreadAttributeList(attrs);
    free(attrs);
    free(cmd);
    free(app);
    if (!ok) {
        last_spawn_errno = lyric_win32_errno(create_err);
        return -1;
    }

    if (isolate) {
        /* The child is still suspended, so nothing it starts can escape the
         * job.  Placing it in one fails only where the parent's own job
         * forbids nesting; the child then runs unconfined and a kill ends
         * it alone. */
        HANDLE job = CreateJobObjectW(NULL, NULL);
        if (job && !AssignProcessToJobObject(job, pi.hProcess)) {
            CloseHandle(job);
            job = NULL;
        }
        child->job = job;
        ResumeThread(pi.hThread);
    }
    CloseHandle(pi.hThread);
    child->process = pi.hProcess;
    return 0;
}

/* Ends the child's tree with LYRIC_KILLED_STATUS.  A child that has
 * already exited keeps its own status. */
static void kill_child(WinChild* c) {
    if (!c->process) return;
    if (!(c->job && TerminateJobObject(c->job, LYRIC_KILLED_STATUS))) {
        TerminateProcess(c->process, LYRIC_KILLED_STATUS);
    }
}

/* Waits up to `wait_ms` for the child; 1 with its status when it has
 * exited, 0 otherwise. */
static int wait_child(WinChild* c, DWORD wait_ms, int32_t* out_status) {
    if (!c->process) return 0;
    if (WaitForSingleObject(c->process, wait_ms) != WAIT_OBJECT_0) return 0;
    DWORD code = 0;
    if (!GetExitCodeProcess(c->process, &code)) code = (DWORD)-1;
    *out_status = (int32_t)code;
    return 1;
}

static void close_child(WinChild* c) {
    if (c->process) CloseHandle(c->process);
    if (c->job) CloseHandle(c->job);
    child_init(c);
}

/* Captured child: three fresh pipes.  0 on success, -1 with
 * last_spawn_errno set (nothing left open) otherwise. */
static int spawn_capture(const char* path, LyricList* args, WinPipe* in_wr, WinPipe* out_rd, WinPipe* err_rd,
                         WinChild* child) {
    HANDLE in_child, out_child, err_child;
    if (make_pipe(out_rd, &out_child, 1) != 0) {
        last_spawn_errno = errno;
        return -1;
    }
    if (make_pipe(err_rd, &err_child, 1) != 0) {
        last_spawn_errno = errno;
        winpipe_close(out_rd);
        close_child_handle(&out_child);
        return -1;
    }
    if (make_pipe(in_wr, &in_child, 0) != 0) {
        last_spawn_errno = errno;
        winpipe_close(out_rd);
        winpipe_close(err_rd);
        close_child_handle(&out_child);
        close_child_handle(&err_child);
        return -1;
    }
    int rc = spawn_child(path, args, in_child, out_child, err_child, 1, child);
    close_child_handle(&in_child);
    close_child_handle(&out_child);
    close_child_handle(&err_child);
    if (rc != 0) {
        winpipe_close(in_wr);
        winpipe_close(out_rd);
        winpipe_close(err_rd);
        return -1;
    }
    return 0;
}

/* ── Blocking capture (lyric_process_run) ──────────────────────────── */

static DWORD clamp_wait_ms(int64_t ms) {
    if (ms <= 0) return 0;
    if (ms >= (int64_t)INFINITE) return INFINITE - 1;
    return (DWORD)ms;
}

/* Issues the next stdin write when none is in flight.  Returns 0 while
 * content remains, 1 once the end can be closed. */
static int feed_stdin(WinPipe* in, const uint8_t* data, int64_t len, int64_t* off) {
    if (in->pending || *off >= len) return *off >= len;
    int64_t left = len - *off;
    DWORD n = left > LYRIC_WRITE_CHUNK ? LYRIC_WRITE_CHUNK : (DWORD)left;
    if (winpipe_write_start(in, data + *off, n) == PIPE_EOF) {
        *off = len; /* the child closed its stdin: drop the rest */
        return 1;
    }
    return 0;
}

/* Completes a finished stdin write.  Returns 1 once the end can be closed. */
static int finish_stdin(WinPipe* in, int64_t len, int64_t* off) {
    DWORD n = 0;
    int r = winpipe_collect(in, 0, &n);
    if (r == PIPE_PENDING) return 0;
    if (r == PIPE_EOF) {
        *off = len;
    } else {
        *off += n;
    }
    return *off >= len;
}

int32_t lyric_process_run(const char* path, LyricList* args, LyricString* stdin_content, int32_t timeout_ms,
                          int32_t* out_exit_code, LyricString** out_stdout, LyricString** out_stderr,
                          int32_t* out_timed_out) {
    WinPipe in, out, err;
    WinChild child;
    if (spawn_capture(path, args, &in, &out, &err, &child) != 0) return -1;

    const uint8_t* in_data = stdin_content ? LYRIC_STRING_DATA(stdin_content) : NULL;
    int64_t in_len = stdin_content ? lyric_string_len(stdin_content) : 0;
    int64_t in_off = 0;
    if (in_len == 0) winpipe_close(&in);

    int64_t deadline_ns = timeout_ms >= 0 ? lyric_monotonic_nanos() + (int64_t)timeout_ms * 1000000 : -1;
    int killed = 0;
    int64_t kill_ns = 0;

    ProcBuf outbuf = {NULL, 0, 0};
    ProcBuf errbuf = {NULL, 0, 0};

    while (winpipe_open(&out) || winpipe_open(&err)) {
        winpipe_pump_read(&out, &outbuf);
        winpipe_pump_read(&err, &errbuf);
        if (winpipe_open(&in)) {
            if ((in.pending && finish_stdin(&in, in_len, &in_off)) || feed_stdin(&in, in_data, in_len, &in_off)) {
                winpipe_close(&in);
            }
        }
        if (!winpipe_open(&out) && !winpipe_open(&err)) break;

        /* Same waits as the POSIX twin: until the deadline, then, after a
         * kill, 100 ms windows under a 2 s drain budget, so a descendant
         * outside the job that still holds a pipe cannot stall the run. */
        DWORD wait_ms = INFINITE;
        if (killed) {
            if (lyric_monotonic_nanos() - kill_ns > 2000000000LL) break;
            wait_ms = 100;
        } else if (deadline_ns >= 0) {
            int64_t left_ns = deadline_ns - lyric_monotonic_nanos();
            wait_ms = left_ns <= 0 ? 0 : clamp_wait_ms(left_ns / 1000000 + 1);
        }
        HANDLE events[3];
        DWORD n_events = 0;
        if (out.pending) events[n_events++] = out.ov.hEvent;
        if (err.pending) events[n_events++] = err.ov.hEvent;
        if (winpipe_open(&in) && in.pending) events[n_events++] = in.ov.hEvent;
        DWORD w = n_events > 0 ? WaitForMultipleObjects(n_events, events, FALSE, wait_ms) : WAIT_TIMEOUT;
        if (w == WAIT_TIMEOUT) {
            if (killed) break; /* post-kill drain exhausted */
            if (deadline_ns < 0 || lyric_monotonic_nanos() < deadline_ns) continue;
            kill_child(&child);
            killed = 1;
            kill_ns = lyric_monotonic_nanos();
            winpipe_close(&in);
        } else if (w == WAIT_FAILED) {
            break; /* give up capturing; still reap the child below */
        }
    }
    winpipe_close(&in);
    winpipe_close(&out);
    winpipe_close(&err);

    int32_t status = -1;
    if (!wait_child(&child, INFINITE, &status)) {
        close_child(&child);
        free(outbuf.data);
        free(errbuf.data);
        return -1;
    }
    close_child(&child);
    /* #5107: a child that exited on its own before the kill landed keeps
     * its status and is not a timeout. */
    *out_exit_code = status;
    *out_stdout = lyric_string_from_literal(outbuf.data, outbuf.len);
    *out_stderr = lyric_string_from_literal(errbuf.data, errbuf.len);
    if (out_timed_out) *out_timed_out = killed && status == LYRIC_KILLED_STATUS ? 1 : 0;
    free(outbuf.data);
    free(errbuf.data);
    return 0;
}

int32_t lyric_process_last_spawn_errno(void) {
    return last_spawn_errno;
}

/* The UCRT's strerror keeps its buffer per thread. */
LyricString* lyric_process_errno_message(int32_t e) {
    const char* m = strerror((int)e);
    return lyric_string_from_literal((const uint8_t*)m, (int64_t)strlen(m));
}

/* Inherited-stdio run: the child shares this process's standard streams
 * and console (and so its Ctrl+C), as on POSIX. */
int32_t lyric_process_run_inherited(const char* path, LyricList* args, int32_t* out_exit_code) {
    HANDLE in = inheritable_std_handle(STD_INPUT_HANDLE);
    HANDLE out = inheritable_std_handle(STD_OUTPUT_HANDLE);
    HANDLE err = inheritable_std_handle(STD_ERROR_HANDLE);
    WinChild child;
    int rc = spawn_child(path, args, in, out, err, 0, &child);
    close_child_handle(&in);
    close_child_handle(&out);
    close_child_handle(&err);
    if (rc != 0) return -1;
    int32_t status = -1;
    int exited = wait_child(&child, INFINITE, &status);
    close_child(&child);
    if (!exited) {
        last_spawn_errno = EIO;
        return -1;
    }
    *out_exit_code = status;
    return 0;
}

/* ── Nonblocking capture op (the async process leaf, D-N-023) ───────── */

typedef struct LyricProcOp {
    WinChild child;
    WinPipe out;
    WinPipe err;
    WinPipe in;
    ProcBuf outbuf;
    ProcBuf errbuf;
    uint8_t* stdin_data; /* owned copy: the caller's string may die first */
    int64_t stdin_len;
    int64_t stdin_off;
    int32_t spawn_failed;
    int32_t done;
    int32_t exit_code;
} LyricProcOp;

void* lyric_process_start(const char* path, LyricList* args, LyricString* stdin_content) {
    LyricProcOp* op = (LyricProcOp*)calloc(1, sizeof(LyricProcOp));
    if (!op) lyric_panic_msg("OOM starting process op", "lyric_process_win32.c", __LINE__);
    winpipe_init(&op->out);
    winpipe_init(&op->err);
    winpipe_init(&op->in);
    child_init(&op->child);
    op->exit_code = -1;
    int64_t in_len = stdin_content ? lyric_string_len(stdin_content) : 0;
    if (in_len > 0) {
        op->stdin_data = (uint8_t*)malloc((size_t)in_len);
        if (!op->stdin_data) lyric_panic_msg("OOM copying process stdin", "lyric_process_win32.c", __LINE__);
        memcpy(op->stdin_data, LYRIC_STRING_DATA(stdin_content), (size_t)in_len);
        op->stdin_len = in_len;
    }
    if (spawn_capture(path, args, &op->in, &op->out, &op->err, &op->child) != 0) {
        op->spawn_failed = 1;
        op->done = 1;
        return op;
    }
    if (op->stdin_len == 0) winpipe_close(&op->in);
    return op;
}

int32_t lyric_process_spawn_failed(void* raw) {
    return ((LyricProcOp*)raw)->spawn_failed;
}

/* One nonblocking step: advance stdin, drain available output, and once
 * both output pipes reach end of stream, check whether the child exited. */
int32_t lyric_process_pump(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    if (op->done) return 1;
    while (winpipe_open(&op->in)) {
        if (op->in.pending) {
            if (finish_stdin(&op->in, op->stdin_len, &op->stdin_off)) {
                winpipe_close(&op->in);
                break;
            }
            if (op->in.pending) break; /* the pipe is full; retry next pump */
        }
        if (feed_stdin(&op->in, op->stdin_data, op->stdin_len, &op->stdin_off)) {
            winpipe_close(&op->in);
            break;
        }
    }
    winpipe_pump_read(&op->out, &op->outbuf);
    winpipe_pump_read(&op->err, &op->errbuf);
    if (!winpipe_open(&op->out) && !winpipe_open(&op->err)) {
        int32_t status = -1;
        if (wait_child(&op->child, 0, &status)) {
            op->exit_code = status;
            op->done = 1;
        }
    }
    return op->done;
}

/* Timeout path: end the child's tree, keep what already arrived, close the
 * pipes and collect the status.  Returns 1 when the kill ended the child,
 * 0 when it had already exited (#5107). */
int32_t lyric_process_kill(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    if (op->done) return 0;
    kill_child(&op->child);
    winpipe_close(&op->in);
    winpipe_pump_read(&op->out, &op->outbuf);
    winpipe_pump_read(&op->err, &op->errbuf);
    winpipe_close(&op->out);
    winpipe_close(&op->err);
    int32_t status = -1;
    int exited = wait_child(&op->child, INFINITE, &status);
    op->exit_code = exited ? status : -1;
    op->done = 1;
    return exited && status == LYRIC_KILLED_STATUS ? 1 : 0;
}

int32_t lyric_process_exit_code(void* raw) {
    return ((LyricProcOp*)raw)->exit_code;
}

LyricString* lyric_process_stdout(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    return lyric_string_from_literal(op->outbuf.data, op->outbuf.len);
}

LyricString* lyric_process_stderr(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    return lyric_string_from_literal(op->errbuf.data, op->errbuf.len);
}

void lyric_process_free(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    winpipe_close(&op->out);
    winpipe_close(&op->err);
    winpipe_close(&op->in);
    close_child(&op->child);
    free(op->stdin_data);
    free(op->outbuf.data);
    free(op->errbuf.data);
    free(op);
}

/* ── Long-lived piped child stdio (issue #6142) ────────────────────────
 *
 * Only stdin and stdout are piped; stderr stays inherited from this process,
 * as on every other target (lyric_process.c explains why). */

typedef struct LyricPipedProc {
    WinChild child;
    WinPipe stdin_wr;
    WinPipe stdout_rd;
    ProcBuf linebuf;      /* buffered stdout bytes; [line_head, len) not yet returned */
    int64_t line_head;    /* start of the unreturned bytes in linebuf */
    int64_t line_scanned; /* bytes from line_head known to hold no '\n' */
    int reaped;
    int32_t exit_code;
    int closed;
} LyricPipedProc;

void* lyric_process_piped_spawn(const char* path, LyricList* args) {
    LyricPipedProc* p = (LyricPipedProc*)calloc(1, sizeof(LyricPipedProc));
    if (!p) lyric_panic_msg("OOM starting piped process", "lyric_process_win32.c", __LINE__);
    p->exit_code = -1;
    HANDLE in_child, out_child;
    if (make_pipe(&p->stdout_rd, &out_child, 1) != 0) {
        last_spawn_errno = errno;
        free(p);
        return NULL;
    }
    if (make_pipe(&p->stdin_wr, &in_child, 0) != 0) {
        last_spawn_errno = errno;
        winpipe_close(&p->stdout_rd);
        close_child_handle(&out_child);
        free(p);
        return NULL;
    }
    HANDLE err = inheritable_std_handle(STD_ERROR_HANDLE);
    int rc = spawn_child(path, args, in_child, out_child, err, 1, &p->child);
    close_child_handle(&in_child);
    close_child_handle(&out_child);
    close_child_handle(&err);
    if (rc != 0) {
        winpipe_close(&p->stdin_wr);
        winpipe_close(&p->stdout_rd);
        free(p);
        return NULL;
    }
    return p;
}

int32_t lyric_process_piped_read_line(void* raw, LyricString** out_line) {
    return lyric_process_piped_read_line_within(raw, out_line, -1);
}

/* Once the deadline has passed, a bounded read still takes bytes that are
 * already in the pipe (#7523), capped so a child that keeps writing cannot
 * stretch the wait. */
#define PIPED_LATE_DRAIN_MAX 65536

/* Returns 1 with *out_line set on a line, 0 at end of stream, 2 on timeout.
 * A read still in flight when the deadline passes stays in flight, so the
 * bytes it brings are kept for the next call. */
int32_t lyric_process_piped_read_line_within(void* raw, LyricString** out_line, int32_t timeout_ms) {
    LyricPipedProc* p = (LyricPipedProc*)raw;
    int64_t deadline_ns = timeout_ms < 0 ? -1 : lyric_monotonic_nanos() + (int64_t)timeout_ms * 1000000;
    int64_t late_bytes = 0;
    for (;;) {
        int64_t head = p->line_head;
        int64_t from = head + p->line_scanned;
        const uint8_t* nl = NULL;
        if (from < p->linebuf.len) {
            nl = (const uint8_t*)memchr(p->linebuf.data + from, '\n', (size_t)(p->linebuf.len - from));
        }
        if (nl) {
            int64_t i = (int64_t)(nl - p->linebuf.data);
            int64_t end = i;
            if (end > head && p->linebuf.data[end - 1] == '\r') end--;
            *out_line = lyric_string_from_literal(p->linebuf.data + head, end - head);
            p->line_head = i + 1;
            p->line_scanned = 0;
            if (p->line_head == p->linebuf.len) {
                p->linebuf.len = 0;
                p->line_head = 0;
            }
            return 1;
        }
        p->line_scanned = p->linebuf.len - head;
        if (!winpipe_open(&p->stdout_rd)) {
            int64_t rest = p->linebuf.len - head;
            p->linebuf.len = 0;
            p->line_head = 0;
            p->line_scanned = 0;
            if (rest > 0) {
                *out_line = lyric_string_from_literal(p->linebuf.data + head, rest);
                return 1;
            }
            return 0;
        }
        if (head > 0) {
            int64_t rest = p->linebuf.len - head;
            memmove(p->linebuf.data, p->linebuf.data + head, (size_t)rest);
            p->linebuf.len = rest;
            p->line_head = 0;
        }
        if (winpipe_read_start(&p->stdout_rd) == PIPE_EOF) {
            winpipe_close(&p->stdout_rd);
            continue;
        }
        DWORD wait_ms = INFINITE;
        int late = 0;
        if (deadline_ns >= 0) {
            int64_t left_ns = deadline_ns - lyric_monotonic_nanos();
            if (left_ns <= 0) {
                if (late_bytes >= PIPED_LATE_DRAIN_MAX) return 2;
                wait_ms = 0;
                late = 1;
            } else {
                wait_ms = clamp_wait_ms((left_ns + 999999) / 1000000);
            }
        }
        DWORD n = 0;
        int r = winpipe_collect(&p->stdout_rd, wait_ms, &n);
        if (r == PIPE_PENDING) {
            if (deadline_ns < 0) continue;
            if (late) return 2;
            continue; /* the deadline passed while waiting: one late check */
        }
        if (r == PIPE_EOF) {
            winpipe_close(&p->stdout_rd);
            continue;
        }
        if (n > 0) {
            procbuf_append(&p->linebuf, p->stdout_rd.buf, n);
            if (late) late_bytes += n;
        }
    }
}

/* Writes `n` bytes, waiting until the pipe accepts all of them.  0 on
 * success, -1 when the child's end is gone. */
static int piped_write_all(WinPipe* w, const uint8_t* data, int64_t n) {
    int64_t off = 0;
    while (off < n) {
        int64_t left = n - off;
        DWORD chunk = left > LYRIC_WRITE_CHUNK ? LYRIC_WRITE_CHUNK : (DWORD)left;
        if (winpipe_write_start(w, data + off, chunk) == PIPE_EOF) return -1;
        DWORD done = 0;
        if (winpipe_collect(w, INFINITE, &done) != PIPE_DONE) return -1;
        off += done;
    }
    return 0;
}

int32_t lyric_process_piped_write_line(void* raw, LyricString* line) {
    LyricPipedProc* p = (LyricPipedProc*)raw;
    if (!winpipe_open(&p->stdin_wr)) return -2;
    int64_t len = line ? lyric_string_len(line) : 0;
    const uint8_t* data = line ? LYRIC_STRING_DATA(line) : NULL;
    if (len > 0 && piped_write_all(&p->stdin_wr, data, len) != 0) return -1;
    static const uint8_t nl = (uint8_t)'\n';
    return piped_write_all(&p->stdin_wr, &nl, 1) == 0 ? 0 : -1;
}

/* After lyric_process_piped_close the process handle is released, so the
 * calls below report the child as gone. */
int32_t lyric_process_piped_is_alive(void* raw) {
    LyricPipedProc* p = (LyricPipedProc*)raw;
    if (p->reaped || !p->child.process) return 0;
    int32_t status = -1;
    if (wait_child(&p->child, 0, &status)) {
        p->exit_code = status;
        p->reaped = 1;
        return 0;
    }
    return 1;
}

int32_t lyric_process_piped_kill(void* raw) {
    LyricPipedProc* p = (LyricPipedProc*)raw;
    if (p->reaped || !p->child.process) return 0;
    kill_child(&p->child);
    int32_t status = -1;
    p->exit_code = wait_child(&p->child, INFINITE, &status) ? status : -1;
    p->reaped = 1;
    return 0;
}

int32_t lyric_process_piped_wait_exit(void* raw, int32_t timeout_ms) {
    LyricPipedProc* p = (LyricPipedProc*)raw;
    if (p->reaped || !p->child.process) return 1;
    int32_t status = -1;
    if (wait_child(&p->child, timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms, &status)) {
        p->exit_code = status;
        p->reaped = 1;
        return 1;
    }
    return 0;
}

int32_t lyric_process_piped_exit_code(void* raw) {
    return ((LyricPipedProc*)raw)->exit_code;
}

int32_t lyric_process_piped_close_stdin(void* raw) {
    winpipe_close(&((LyricPipedProc*)raw)->stdin_wr);
    return 0;
}

/* Releases the pipes and the process handle without waiting for or killing
 * the child.  Idempotent; the handle itself is retained for the rest of the
 * process's life, as on POSIX (issue #6975), so a second call is safe. */
void lyric_process_piped_close(void* raw) {
    LyricPipedProc* p = (LyricPipedProc*)raw;
    if (p->closed) return;
    p->closed = 1;
    winpipe_close(&p->stdin_wr);
    winpipe_close(&p->stdout_rd);
    close_child(&p->child);
    free(p->linebuf.data);
    p->linebuf.data = NULL;
    p->linebuf.len = 0;
    p->linebuf.cap = 0;
    p->line_head = 0;
    p->line_scanned = 0;
    lyric_lsan_ignore_leak(p);
}
