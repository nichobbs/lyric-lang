/* lyric_win32.c — the Windows twin of lyric_posix.c (docs/67 G9): console
 * I/O, the fixed-width libc wrappers, protected-type monitors, semaphores,
 * condition variables, threads, clocks and entropy over the Win32 API.
 *
 * File descriptors are UCRT descriptors (`_wopen`), opened in binary mode
 * and never inherited by child processes, so the Lyric kernels keep the
 * same int-fd shape on every target.  Paths are UTF-8 and cross into the
 * wide ("W") entry points (lyric_win32_internal.h).
 *
 * Console output that reaches a real console is written as UTF-16 with
 * WriteConsoleW, so non-ASCII text shows correctly whatever the console code
 * page is; redirected output (a pipe or a file) is written byte for byte,
 * keeping the UTF-8 the program produced.
 */
#include "lyric_rt.h"
#include "lyric_win32_internal.h"

#include <bcrypt.h>
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <process.h>
#include <share.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* ── UTF-8 / UTF-16 conversion ─────────────────────────────────────── */

wchar_t* lyric_win32_wide(const char* s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n) != n) {
        free(w);
        return NULL;
    }
    return w;
}

char* lyric_win32_utf8(const wchar_t* w, int64_t n, int64_t* out_len) {
    if (n < 0) n = (int64_t)wcslen(w);
    if (n > INT32_MAX) return NULL;
    int bytes = n == 0 ? 0 : WideCharToMultiByte(CP_UTF8, 0, w, (int)n, NULL, 0, NULL, NULL);
    if (n > 0 && bytes <= 0) return NULL;
    char* s = (char*)malloc((size_t)bytes + 1);
    if (!s) return NULL;
    if (bytes > 0 && WideCharToMultiByte(CP_UTF8, 0, w, (int)n, s, bytes, NULL, NULL) != bytes) {
        free(s);
        return NULL;
    }
    s[bytes] = '\0';
    if (out_len) *out_len = bytes;
    return s;
}

/* 100 ns ticks between 1601-01-01 and 1970-01-01. */
#define LYRIC_FILETIME_UNIX_EPOCH 116444736000000000LL

int64_t lyric_win32_filetime_to_unix_nanos(FILETIME ft) {
    int64_t ticks = (int64_t)(((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime);
    return (ticks - LYRIC_FILETIME_UNIX_EPOCH) * 100;
}

/* Map the calling thread's last Win32 error onto errno, for the wrappers
 * that keep the POSIX "-1 and errno" convention. */
static void set_errno_from_win32(void) {
    switch (GetLastError()) {
    case ERROR_FILE_NOT_FOUND:
    case ERROR_PATH_NOT_FOUND:
    case ERROR_INVALID_NAME:
    case ERROR_BAD_NETPATH:
        errno = ENOENT;
        break;
    case ERROR_ALREADY_EXISTS:
    case ERROR_FILE_EXISTS:
        errno = EEXIST;
        break;
    case ERROR_ACCESS_DENIED:
    case ERROR_SHARING_VIOLATION:
    case ERROR_LOCK_VIOLATION:
        errno = EACCES;
        break;
    case ERROR_DIR_NOT_EMPTY:
        errno = ENOTEMPTY;
        break;
    case ERROR_DIRECTORY:
        errno = ENOTDIR;
        break;
    case ERROR_NOT_ENOUGH_MEMORY:
    case ERROR_OUTOFMEMORY:
        errno = ENOMEM;
        break;
    default:
        errno = EIO;
        break;
    }
}

/* ── Process start-up ──────────────────────────────────────────────── */

/* The CRT's default response to an invalid argument (a closed or negative
 * descriptor, say) is to end the process; returning instead makes the call
 * fail with errno set (EBADF, EINVAL), the POSIX behaviour every caller in
 * the runtime already handles. */
static void lyric_win32_invalid_parameter(const wchar_t* expr, const wchar_t* func, const wchar_t* file,
                                          unsigned int line, uintptr_t reserved) {
    (void)expr;
    (void)func;
    (void)file;
    (void)line;
    (void)reserved;
}

/* Standard streams start in text mode in the CRT, which would turn every
 * "\n" into "\r\n" and stop reads at a 0x1A byte; Lyric's streams are byte
 * streams on every target.  A panic aborts without the CRT's message box or
 * Windows Error Reporting dialog, so a failing program in CI or a terminal
 * exits (status 3) instead of hanging on a window nobody can click. */
__attribute__((constructor)) static void lyric_win32_startup(void) {
    _set_invalid_parameter_handler(lyric_win32_invalid_parameter);
    _setmode(0, _O_BINARY);
    _setmode(1, _O_BINARY);
    _setmode(2, _O_BINARY);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
}

/* ── Console output ────────────────────────────────────────────────── */

/* The console handle behind `fd`, or NULL when `fd` is not attached to a
 * console (redirected to a pipe or a file, or not a standard stream). */
static HANDLE console_handle(int32_t fd) {
    if (fd != 1 && fd != 2) return NULL;
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    DWORD mode;
    if (h == INVALID_HANDLE_VALUE || !GetConsoleMode(h, &mode)) return NULL;
    return h;
}

/* Bytes of a UTF-8 sequence split across two console writes, held until the
 * rest arrives so the character is converted whole.  Index 0 is stdout,
 * 1 is stderr.  Console writes come from one thread at a time per line
 * (Std.Console's contract), so this is not locked. */
static uint8_t console_carry[2][4];
static int console_carry_len[2];

/* Length of the longest prefix of `p[0..n)` that ends on a UTF-8 sequence
 * boundary: a trailing lead byte whose continuation bytes have not all
 * arrived is excluded. */
static int64_t utf8_complete_prefix(const uint8_t* p, int64_t n) {
    int64_t i = n;
    int back = 0;
    while (i > 0 && back < 3 && (p[i - 1] & 0xC0) == 0x80) {
        i--;
        back++;
    }
    if (i == 0) return n;
    uint8_t lead = p[i - 1];
    int need = (lead & 0x80) == 0 ? 1 : (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3
             : (lead & 0xF8) == 0xF0 ? 4 : 1;
    return (n - (i - 1)) < need ? i - 1 : n;
}

static void console_write_utf16(HANDLE h, const uint8_t* p, int64_t n) {
    while (n > 0) {
        int chunk = n > (1 << 20) ? (1 << 20) : (int)n;
        /* Never split a sequence between chunks. */
        if (chunk < n) chunk = (int)utf8_complete_prefix(p, chunk);
        int wn = MultiByteToWideChar(CP_UTF8, 0, (const char*)p, chunk, NULL, 0);
        if (wn > 0) {
            wchar_t* w = (wchar_t*)malloc((size_t)wn * sizeof(wchar_t));
            if (!w) return; /* best-effort: console output never panics */
            MultiByteToWideChar(CP_UTF8, 0, (const char*)p, chunk, w, wn);
            int off = 0;
            while (off < wn) {
                DWORD wrote = 0;
                if (!WriteConsoleW(h, w + off, (DWORD)(wn - off), &wrote, NULL) || wrote == 0) break;
                off += (int)wrote;
            }
            free(w);
        }
        p += chunk;
        n -= chunk;
    }
}

/* Converts and writes the complete UTF-8 sequences of carry ++ data, keeping
 * a trailing incomplete sequence (at most 3 bytes) as the new carry. */
static void console_write(HANDLE con, int slot, const uint8_t* data, int64_t len) {
    const uint8_t* p = data;
    int64_t n = len;
    uint8_t* joined = NULL;
    if (console_carry_len[slot] > 0) {
        n = console_carry_len[slot] + len;
        joined = (uint8_t*)malloc((size_t)n);
        if (!joined) return; /* best-effort: console output never panics */
        memcpy(joined, console_carry[slot], (size_t)console_carry_len[slot]);
        memcpy(joined + console_carry_len[slot], data, (size_t)len);
        p = joined;
    }
    int64_t whole = utf8_complete_prefix(p, n);
    console_write_utf16(con, p, whole);
    console_carry_len[slot] = (int)(n - whole);
    memcpy(console_carry[slot], p + whole, (size_t)(n - whole));
    free(joined);
}

static void write_all(int32_t fd, const uint8_t* data, int64_t len) {
    HANDLE con = console_handle(fd);
    if (con) {
        console_write(con, fd - 1, data, len);
        return;
    }
    int64_t off = 0;
    while (off < len) {
        int64_t left = len - off;
        unsigned chunk = left > (1 << 30) ? (1u << 30) : (unsigned)left;
        int n = _write(fd, data + off, chunk);
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

/* The text and its newline go out as one write, so concurrent printers do
 * not split a line from its newline (lyric_posix.c does the same with one
 * writev). */
void lyric_console_write_line(int32_t fd, LyricString* s) {
    int64_t len = s ? s->len : 0;
    uint8_t stackbuf[512];
    uint8_t* buf = len + 1 <= (int64_t)sizeof stackbuf ? stackbuf : (uint8_t*)malloc((size_t)len + 1);
    if (!buf) {
        if (len > 0) write_all(fd, LYRIC_STRING_DATA(s), len);
        lyric_console_write_newline(fd);
        return;
    }
    if (len > 0) memcpy(buf, LYRIC_STRING_DATA(s), (size_t)len);
    buf[len] = '\n';
    write_all(fd, buf, len + 1);
    if (buf != stackbuf) free(buf);
}

/* ── Console input ─────────────────────────────────────────────────────
 * Same contract as lyric_posix.c: a line read consumes nothing past its
 * terminator, except the one byte after a bare '\r', held in
 * stdin_pending.  A console delivers UTF-16, which is converted to UTF-8 a
 * line at a time into console_in; a pipe or a file is read byte for byte.
 * Std.Console allows one stdin reader per process, so this is not locked. */
static int32_t stdin_pending = -1;
static uint8_t* console_in = NULL;
static int64_t console_in_len = 0;
static int64_t console_in_pos = 0;

static HANDLE stdin_handle(void) {
    return (HANDLE)_get_osfhandle(0);
}

static int stdin_is_console(HANDLE h) {
    DWORD mode;
    return h != INVALID_HANDLE_VALUE && GetConsoleMode(h, &mode);
}

/* Refill console_in from ReadConsoleW: 1 when bytes are buffered, 0 at end
 * of input (Ctrl+Z on an empty line), -1 on error. */
static int console_fill(HANDLE h) {
    wchar_t wbuf[4096];
    DWORD got = 0;
    if (!ReadConsoleW(h, wbuf, (DWORD)(sizeof wbuf / sizeof wbuf[0]), &got, NULL)) return -1;
    if (got == 0) return 0;
    /* Ctrl+Z at the start of a read is the console's end-of-file mark. */
    if (wbuf[0] == 0x1A) return 0;
    int64_t n = 0;
    char* bytes = lyric_win32_utf8(wbuf, (int64_t)got, &n);
    if (!bytes) return -1;
    free(console_in);
    console_in = (uint8_t*)bytes;
    console_in_len = n;
    console_in_pos = 0;
    return n > 0 ? 1 : console_fill(h);
}

/* One read of up to `cap` bytes: >0 bytes, 0 at end of stream, -1 on error. */
static int64_t stdin_read_raw(uint8_t* buf, int64_t cap) {
    HANDLE h = stdin_handle();
    if (stdin_is_console(h)) {
        if (console_in_pos >= console_in_len) {
            int rc = console_fill(h);
            if (rc <= 0) return rc;
        }
        int64_t avail = console_in_len - console_in_pos;
        int64_t n = avail < cap ? avail : cap;
        memcpy(buf, console_in + console_in_pos, (size_t)n);
        console_in_pos += n;
        return n;
    }
    unsigned chunk = cap > (1 << 30) ? (1u << 30) : (unsigned)cap;
    for (;;) {
        int n = _read(0, buf, chunk);
        if (n >= 0) return n;
        if (errno != EINTR) return -1;
    }
}

/* Whether a read of stdin would return without blocking right now: buffered
 * console bytes, a completed console line (an Enter key press waiting in
 * the input queue), pipe data or a closed pipe, or a file. */
static int stdin_ready_now(HANDLE h) {
    if (stdin_pending >= 0 || console_in_pos < console_in_len) return 1;
    if (h == INVALID_HANDLE_VALUE) return 1; /* the read fails at once */
    DWORD mode;
    if (GetConsoleMode(h, &mode)) {
        DWORD count = 0;
        if (!GetNumberOfConsoleInputEvents(h, &count) || count == 0) return 0;
        INPUT_RECORD* recs = (INPUT_RECORD*)malloc((size_t)count * sizeof(INPUT_RECORD));
        if (!recs) return 0;
        DWORD peeked = 0;
        int ready = 0;
        if (PeekConsoleInputW(h, recs, count, &peeked)) {
            for (DWORD i = 0; i < peeked && !ready; i++) {
                if (recs[i].EventType == KEY_EVENT && recs[i].Event.KeyEvent.bKeyDown &&
                    recs[i].Event.KeyEvent.wVirtualKeyCode == VK_RETURN) {
                    ready = 1;
                }
            }
        }
        free(recs);
        return ready;
    }
    if (GetFileType(h) == FILE_TYPE_PIPE) {
        DWORD avail = 0;
        if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) return 1; /* closed: end of stream */
        return avail > 0;
    }
    return 1; /* a file or a character device other than a console */
}

int32_t lyric_stdin_wait(int32_t timeout_ms) {
    HANDLE h = stdin_handle();
    int64_t deadline = timeout_ms >= 0 ? lyric_monotonic_nanos() + (int64_t)timeout_ms * 1000000 : 0;
    for (;;) {
        if (stdin_ready_now(h)) return 1;
        int64_t left = timeout_ms >= 0 ? deadline - lyric_monotonic_nanos() : INT64_MAX;
        if (left <= 0) return 0;
        /* Neither a console line nor an anonymous pipe has a "readable"
         * wait object, so poll in short steps; a console waits on its input
         * event so a key press wakes the loop at once. */
        DWORD step = left < 10000000 ? (DWORD)((left + 999999) / 1000000) : 10;
        DWORD mode;
        if (GetConsoleMode(h, &mode)) {
            WaitForSingleObject(h, step);
            if (!stdin_ready_now(h)) Sleep(1);
        } else {
            Sleep(step);
        }
    }
}

LyricList* lyric_stdin_read(int32_t max, int32_t* ok) {
    if (max <= 0) {
        *ok = 1;
        return lyric_list_from_bytes(NULL, 0);
    }
    uint8_t* buf = (uint8_t*)malloc((size_t)max);
    if (!buf) lyric_panic_msg("out of memory reading stdin", "lyric_win32.c", __LINE__);
    int64_t n = 0;
    if (stdin_pending >= 0) {
        buf[n++] = (uint8_t)stdin_pending;
        stdin_pending = -1;
    } else {
        int64_t got = stdin_read_raw(buf, max);
        if (got < 0) {
            free(buf);
            *ok = 0;
            return lyric_list_from_bytes(NULL, 0);
        }
        n = got;
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
    if (!buf) lyric_panic_msg("out of memory reading stdin", "lyric_win32.c", __LINE__);
    int32_t result = 1;
    for (;;) {
        uint8_t b;
        if (stdin_pending >= 0) {
            b = (uint8_t)stdin_pending;
            stdin_pending = -1;
        } else {
            int64_t got = stdin_read_raw(&b, 1);
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
            int64_t got = stdin_read_raw(&next, 1);
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
                lyric_panic_msg("out of memory reading stdin", "lyric_win32.c", __LINE__);
            }
            buf = grown;
        }
        buf[len++] = b;
    }
    if (result == 1) *out = lyric_string_from_literal(buf, len);
    free(buf);
    return result;
}

/* ── Platform helpers ──────────────────────────────────────────────── */

int32_t lyric_o_rdonly(void) { return _O_RDONLY; }
int32_t lyric_o_wronly(void) { return _O_WRONLY; }
int32_t lyric_o_rdwr(void)   { return _O_RDWR; }
int32_t lyric_o_creat(void)  { return _O_CREAT; }
int32_t lyric_o_trunc(void)  { return _O_TRUNC; }
int32_t lyric_o_append(void) { return _O_APPEND; }

int64_t lyric_file_size(const char* path) {
    wchar_t* w = lyric_win32_wide(path);
    if (!w) return -1;
    WIN32_FILE_ATTRIBUTE_DATA fa;
    BOOL ok = GetFileAttributesExW(w, GetFileExInfoStandard, &fa);
    free(w);
    if (!ok) return -1;
    return (int64_t)(((uint64_t)fa.nFileSizeHigh << 32) | fa.nFileSizeLow);
}

int64_t lyric_write_fd(int32_t fd, const void* buf, int64_t n) {
    if (n < 0) {
        errno = EINVAL;
        return -1;
    }
    unsigned chunk = n > (1 << 30) ? (1u << 30) : (unsigned)n;
    return (int64_t)_write(fd, buf, chunk);
}

int64_t lyric_read_fd(int32_t fd, void* buf, int64_t n) {
    if (n < 0) {
        errno = EINVAL;
        return -1;
    }
    unsigned chunk = n > (1 << 30) ? (1u << 30) : (unsigned)n;
    return (int64_t)_read(fd, buf, chunk);
}

/* POSIX `mode` bits mapped to the one permission Windows files carry: a file
 * created without any write bit is read-only. */
int32_t lyric_open_fd(const char* path, int32_t flags, int32_t mode) {
    wchar_t* w = lyric_win32_wide(path);
    if (!w) {
        errno = ENOENT;
        return -1;
    }
    int pmode = (mode & 0222) ? (_S_IREAD | _S_IWRITE) : _S_IREAD;
    int fd = -1;
    errno_t e = _wsopen_s(&fd, w, flags | _O_BINARY | _O_NOINHERIT, _SH_DENYNO, pmode);
    free(w);
    if (e != 0) {
        errno = e;
        return -1;
    }
    return (int32_t)fd;
}

int64_t lyric_cstr_len(const char* s) {
    return (int64_t)strlen(s);
}

void* lyric_malloc_raw(int64_t n) {
    return malloc((size_t)n);
}

int32_t lyric_close_fd(int32_t fd) {
    return (int32_t)_close(fd);
}

int32_t lyric_unlink(const char* path) {
    wchar_t* w = lyric_win32_wide(path);
    if (!w) {
        errno = ENOENT;
        return -1;
    }
    BOOL ok = DeleteFileW(w);
    if (!ok) set_errno_from_win32();
    free(w);
    return ok ? 0 : -1;
}

int32_t lyric_mkdir(const char* path, int32_t mode) {
    (void)mode;
    wchar_t* w = lyric_win32_wide(path);
    if (!w) {
        errno = ENOENT;
        return -1;
    }
    BOOL ok = CreateDirectoryW(w, NULL);
    if (!ok) set_errno_from_win32();
    free(w);
    return ok ? 0 : -1;
}

int32_t lyric_rmdir(const char* path) {
    wchar_t* w = lyric_win32_wide(path);
    if (!w) {
        errno = ENOENT;
        return -1;
    }
    BOOL ok = RemoveDirectoryW(w);
    if (!ok) set_errno_from_win32();
    free(w);
    return ok ? 0 : -1;
}

/* A high-resolution waitable timer sleeps for the requested time; Sleep()
 * rounds up to the scheduler tick (15.6 ms by default), which would make
 * every short async timer or `Time.sleep` up to a tick late. */
void lyric_sleep_nanos(int64_t ns) {
    if (ns <= 0) return;
    HANDLE t = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (t) {
        LARGE_INTEGER due;
        /* Negative: relative, in 100 ns units, rounded up. */
        due.QuadPart = -((ns + 99) / 100);
        if (SetWaitableTimer(t, &due, 0, NULL, NULL, FALSE)) {
            WaitForSingleObject(t, INFINITE);
            CloseHandle(t);
            return;
        }
        CloseHandle(t);
    }
    int64_t ms = (ns + 999999) / 1000000;
    while (ms > 0) {
        DWORD step = ms > 0x7FFFFFFF ? 0x7FFFFFFF : (DWORD)ms;
        Sleep(step);
        ms -= step;
    }
}

/* ── Protected-type monitors ───────────────────────────────────────────
 * The lyric_posix.c design over Win32 primitives: an SRW lock, the
 * condition variable its `when:` barriers wait on, and the owning thread
 * and nesting depth, so the lock is reentrant and a wait releases every
 * level at once.  An SRW lock and a condition variable need no destruction,
 * so a monitor holds no kernel object. */
typedef struct {
    SRWLOCK lock;
    CONDITION_VARIABLE cond;
    _Atomic DWORD owner;
    _Atomic int32_t depth;
} lyric_monitor_t;

int32_t lyric_mutex_size(void) {
    return (int32_t)sizeof(lyric_monitor_t);
}

void lyric_mutex_init(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    InitializeSRWLock(&mon->lock);
    InitializeConditionVariable(&mon->cond);
    atomic_store_explicit(&mon->owner, 0, memory_order_relaxed);
    atomic_store_explicit(&mon->depth, 0, memory_order_relaxed);
}

/* Same acquire/release pairing on `depth` as lyric_posix.c. */
static int lyric_monitor_held_by_me(lyric_monitor_t* mon) {
    return atomic_load_explicit(&mon->depth, memory_order_acquire) > 0 &&
           atomic_load_explicit(&mon->owner, memory_order_relaxed) == GetCurrentThreadId();
}

void lyric_mutex_lock(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (lyric_monitor_held_by_me(mon)) {
        atomic_store_explicit(&mon->depth, atomic_load_explicit(&mon->depth, memory_order_relaxed) + 1,
                              memory_order_relaxed);
        return;
    }
    AcquireSRWLockExclusive(&mon->lock);
    atomic_store_explicit(&mon->owner, GetCurrentThreadId(), memory_order_relaxed);
    atomic_store_explicit(&mon->depth, 1, memory_order_release);
}

void lyric_mutex_unlock(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("unlock of a lock that is not held", "lyric_win32.c", __LINE__);
    }
    int32_t depth = atomic_load_explicit(&mon->depth, memory_order_relaxed);
    if (depth > 1) {
        atomic_store_explicit(&mon->depth, depth - 1, memory_order_relaxed);
        return;
    }
    atomic_store_explicit(&mon->depth, 0, memory_order_release);
    ReleaseSRWLockExclusive(&mon->lock);
}

void lyric_mutex_destroy(void* m) {
    (void)m;
}

/* Waits on `cv` with the monitor's lock, releasing every nesting level and
 * restoring them on return; `timeout_ms` INFINITE waits without a bound.
 * 1 when woken, 0 when the time ran out. */
static int32_t monitor_wait_on(lyric_monitor_t* mon, CONDITION_VARIABLE* cv, DWORD timeout_ms) {
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("wait on a lock that is not held", "lyric_win32.c", __LINE__);
    }
    int32_t saved = atomic_load_explicit(&mon->depth, memory_order_relaxed);
    atomic_store_explicit(&mon->depth, 0, memory_order_release);
    int32_t woke = 1;
    if (!SleepConditionVariableSRW(cv, &mon->lock, timeout_ms, 0)) {
        if (GetLastError() != ERROR_TIMEOUT) {
            lyric_panic_msg("SleepConditionVariableSRW failed", "lyric_win32.c", __LINE__);
        }
        woke = 0;
    }
    atomic_store_explicit(&mon->owner, GetCurrentThreadId(), memory_order_relaxed);
    atomic_store_explicit(&mon->depth, saved, memory_order_release);
    return woke;
}

void lyric_mutex_wait(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    monitor_wait_on(mon, &mon->cond, INFINITE);
}

void lyric_mutex_notify_all(void* m) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("notify on a lock that is not held", "lyric_win32.c", __LINE__);
    }
    WakeAllConditionVariable(&mon->cond);
}

/* A relative timeout in nanoseconds as the milliseconds a Win32 wait takes,
 * rounded up so a wait is never shorter than asked, and kept below
 * INFINITE. */
static DWORD timeout_ns_to_ms(int64_t timeout_ns) {
    int64_t ms = (timeout_ns + 999999) / 1000000;
    return ms >= (int64_t)INFINITE ? INFINITE - 1 : (DWORD)ms;
}

/* ── Semaphores ────────────────────────────────────────────────────── */

typedef struct {
    SRWLOCK lock;
    CONDITION_VARIABLE cond;
    int32_t count;
} lyric_sem_t;

int32_t lyric_sem_size(void) {
    return (int32_t)sizeof(lyric_sem_t);
}

void lyric_sem_init(void* s, int32_t initial) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    InitializeSRWLock(&sem->lock);
    InitializeConditionVariable(&sem->cond);
    sem->count = initial;
}

void lyric_sem_wait(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    AcquireSRWLockExclusive(&sem->lock);
    while (sem->count <= 0) {
        if (!SleepConditionVariableSRW(&sem->cond, &sem->lock, INFINITE, 0)) {
            lyric_panic_msg("SleepConditionVariableSRW (sem) failed", "lyric_win32.c", __LINE__);
        }
    }
    sem->count -= 1;
    ReleaseSRWLockExclusive(&sem->lock);
}

int32_t lyric_sem_trywait(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    int32_t acquired = 0;
    AcquireSRWLockExclusive(&sem->lock);
    if (sem->count > 0) {
        sem->count -= 1;
        acquired = 1;
    }
    ReleaseSRWLockExclusive(&sem->lock);
    return acquired;
}

void lyric_sem_post(void* s) {
    lyric_sem_t* sem = (lyric_sem_t*)s;
    AcquireSRWLockExclusive(&sem->lock);
    sem->count += 1;
    WakeConditionVariable(&sem->cond);
    ReleaseSRWLockExclusive(&sem->lock);
}

void lyric_sem_destroy(void* s) {
    (void)s;
}

/* ── Condition variables ───────────────────────────────────────────────
 * Win32 waits take a relative timeout measured on the interrupt-time clock,
 * so a wall-clock step cannot cut one short or stretch it (the property
 * lyric_posix.c gets from CLOCK_MONOTONIC). */
int32_t lyric_cond_size(void) {
    return (int32_t)sizeof(CONDITION_VARIABLE);
}

void lyric_cond_init(void* c) {
    InitializeConditionVariable((CONDITION_VARIABLE*)c);
}

void lyric_cond_wait(void* c, void* m) {
    monitor_wait_on((lyric_monitor_t*)m, (CONDITION_VARIABLE*)c, INFINITE);
}

int32_t lyric_cond_timedwait(void* c, void* m, int64_t timeout_ns) {
    lyric_monitor_t* mon = (lyric_monitor_t*)m;
    if (!lyric_monitor_held_by_me(mon)) {
        lyric_panic_msg("wait on a lock that is not held", "lyric_win32.c", __LINE__);
    }
    if (timeout_ns <= 0) return 0;
    return monitor_wait_on(mon, (CONDITION_VARIABLE*)c, timeout_ns_to_ms(timeout_ns));
}

void lyric_cond_signal(void* c) {
    WakeConditionVariable((CONDITION_VARIABLE*)c);
}

void lyric_cond_broadcast(void* c) {
    WakeAllConditionVariable((CONDITION_VARIABLE*)c);
}

void lyric_cond_destroy(void* c) {
    (void)c;
}

/* ── Clocks ────────────────────────────────────────────────────────── */

int64_t lyric_epoch_millis(void) {
    return lyric_epoch_nanos() / 1000000;
}

int64_t lyric_epoch_nanos(void) {
    FILETIME ft;
    GetSystemTimePreciseAsFileTime(&ft);
    return lyric_win32_filetime_to_unix_nanos(ft);
}

int64_t lyric_monotonic_nanos(void) {
    static LARGE_INTEGER freq; /* constant after boot; racing first writers store the same value */
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    /* Split so the multiply cannot overflow for any uptime. */
    int64_t whole = c.QuadPart / freq.QuadPart;
    int64_t part = c.QuadPart % freq.QuadPart;
    return whole * 1000000000LL + part * 1000000000LL / freq.QuadPart;
}

/* ── Entropy and UUIDs ─────────────────────────────────────────────── */

LyricString* lyric_uuid_v4(void) {
    uint8_t b[16];
    if (lyric_secure_random(b, 16) != 0) {
        lyric_panic_msg("cannot draw entropy for a v4 UUID", "lyric_win32.c", __LINE__);
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
        lyric_panic_msg("secure random byte count must not be negative", "lyric_win32.c", __LINE__);
    }
    uint8_t* buf = (uint8_t*)malloc(n > 0 ? (size_t)n : 1);
    if (buf == NULL) {
        lyric_panic_msg("out of memory drawing secure random bytes", "lyric_win32.c", __LINE__);
    }
    if (lyric_secure_random(buf, n) != 0) {
        free(buf);
        lyric_panic_msg("cannot draw entropy from the OS", "lyric_win32.c", __LINE__);
    }
    LyricList* list = lyric_list_from_bytes(buf, n);
    free(buf);
    return list;
}

/* The system-preferred RNG (CNG), the source the .NET and Rust standard
 * libraries draw from on Windows. */
int32_t lyric_secure_random(uint8_t* buf, int64_t n) {
    int64_t off = 0;
    while (off < n) {
        int64_t left = n - off;
        ULONG chunk = left > 0x40000000 ? 0x40000000UL : (ULONG)left;
        if (!BCRYPT_SUCCESS(BCryptGenRandom(NULL, buf + off, chunk, BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
            return -1;
        }
        off += chunk;
    }
    return 0;
}

/* ── Threads ───────────────────────────────────────────────────────────
 * A joinable thread's handle is a heap record holding the Win32 handle and
 * the start function's result, which lyric_thread_join hands back the way
 * pthread_join does. */
typedef struct {
    void* (*start)(void*);
    void* arg;
    void* result;
    HANDLE handle;
    int detached;
} lyric_win32_thread;

static unsigned __stdcall lyric_win32_thread_entry(void* p) {
    lyric_win32_thread* t = (lyric_win32_thread*)p;
    void* result = t->start(t->arg);
    if (t->detached) {
        lyric_release(t->arg);
        free(t);
    } else {
        t->result = result;
    }
    return 0;
}

static int32_t start_thread(lyric_win32_thread* t) {
    uintptr_t h = _beginthreadex(NULL, 0, lyric_win32_thread_entry, t, 0, NULL);
    if (h == 0) return errno == 0 ? EAGAIN : errno;
    t->handle = (HANDLE)h;
    return 0;
}

int32_t lyric_thread_create(int64_t* tid, void* (*start)(void*), void* arg) {
    lyric_win32_thread* t = (lyric_win32_thread*)calloc(1, sizeof *t);
    if (!t) return ENOMEM;
    t->start = start;
    t->arg = arg;
    int32_t rc = start_thread(t);
    if (rc != 0) {
        free(t);
        return rc;
    }
    *tid = (int64_t)(intptr_t)t;
    return 0;
}

int32_t lyric_thread_join(int64_t tid, void** retval) {
    lyric_win32_thread* t = (lyric_win32_thread*)(intptr_t)tid;
    if (!t) return ESRCH;
    if (WaitForSingleObject(t->handle, INFINITE) != WAIT_OBJECT_0) return EINVAL;
    CloseHandle(t->handle);
    if (retval) *retval = t->result;
    free(t);
    return 0;
}

int32_t lyric_thread_spawn_detached(void* (*start)(void*), void* arg) {
    lyric_win32_thread* t = (lyric_win32_thread*)calloc(1, sizeof *t);
    if (!t) return ENOMEM;
    t->start = start;
    t->arg = arg;
    t->detached = 1;
    uintptr_t h = _beginthreadex(NULL, 0, lyric_win32_thread_entry, t, CREATE_SUSPENDED, NULL);
    if (h == 0) {
        int32_t rc = errno == 0 ? EAGAIN : errno;
        free(t);
        return rc;
    }
    /* Started suspended so the record is complete before the thread can
     * free it; the handle is not needed once it runs. */
    ResumeThread((HANDLE)h);
    CloseHandle((HANDLE)h);
    return 0;
}

static SRWLOCK lyric_global_mutex = SRWLOCK_INIT;
static CONDITION_VARIABLE lyric_global_cond_var = CONDITION_VARIABLE_INIT;

void lyric_global_lock(void) {
    AcquireSRWLockExclusive(&lyric_global_mutex);
}

void lyric_global_unlock(void) {
    ReleaseSRWLockExclusive(&lyric_global_mutex);
}

void lyric_global_cond_wait(void) {
    if (!SleepConditionVariableSRW(&lyric_global_cond_var, &lyric_global_mutex, INFINITE, 0)) {
        lyric_panic_msg("SleepConditionVariableSRW (global) failed", "lyric_win32.c", __LINE__);
    }
}

int32_t lyric_global_cond_timedwait(int64_t timeout_ns) {
    if (timeout_ns <= 0) return 0;
    if (!SleepConditionVariableSRW(&lyric_global_cond_var, &lyric_global_mutex, timeout_ns_to_ms(timeout_ns), 0)) {
        if (GetLastError() != ERROR_TIMEOUT) {
            lyric_panic_msg("SleepConditionVariableSRW (global) failed", "lyric_win32.c", __LINE__);
        }
        return 0;
    }
    return 1;
}

void lyric_global_cond_broadcast(void) {
    WakeAllConditionVariable(&lyric_global_cond_var);
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
