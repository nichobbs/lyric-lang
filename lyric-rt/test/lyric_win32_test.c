/* lyric_win32_test.c — tests for the Windows-only behaviour of lyric-rt
 * (docs/67 G9): UTF-8 paths through the wide API, byte-exact standard
 * streams, panic exit status, the UTF-16 command line, the Win32
 * environment, stdin readiness on a pipe and timer precision.  The portable
 * behaviour is covered by lyric_rt_test.c, which also runs on Windows.
 *
 * Several cases run this executable again as a child (`--child <case>`)
 * and check what it wrote and how it exited.  Run via
 * `make -C lyric-rt test-windows`.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "lyric_rt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                    \
        }                                                                  \
    } while (0)

static int string_is(LyricString* s, const char* want) {
    size_t n = strlen(want);
    return s && lyric_string_len(s) == (int64_t)n && memcmp(LYRIC_STRING_DATA(s), want, n) == 0;
}

/* A fresh directory under the system temp directory, as UTF-8. */
static void make_temp_dir(char* out, size_t cap) {
    wchar_t base[MAX_PATH + 1];
    DWORD n = GetTempPathW(MAX_PATH + 1, base);
    CHECK(n > 0);
    uint8_t r[4];
    CHECK(lyric_secure_random(r, 4) == 0);
    char tmp[MAX_PATH * 3];
    WideCharToMultiByte(CP_UTF8, 0, base, -1, tmp, (int)sizeof tmp, NULL, NULL);
    snprintf(out, cap, "%slyric_win32_test_%02x%02x%02x%02x", tmp, r[0], r[1], r[2], r[3]);
    CHECK(lyric_dir_create(out) == 0);
}

/* ── Child processes ───────────────────────────────────────────────── */

typedef struct {
    DWORD exit_code;
    char out[4096];
    DWORD out_len;
    char err[4096];
    DWORD err_len;
} child_result;

static void read_all_handle(HANDLE h, char* buf, DWORD cap, DWORD* len) {
    *len = 0;
    for (;;) {
        DWORD got = 0;
        if (*len >= cap - 1 || !ReadFile(h, buf + *len, cap - 1 - *len, &got, NULL) || got == 0) break;
        *len += got;
    }
    buf[*len] = '\0';
}

/* Runs this executable with `args` (UTF-16, appended after the program
 * name), writing `stdin_bytes` (NULL: nothing) to its stdin pipe after
 * `stdin_delay_ms` and then closing it, and capturing stdout and stderr. */
static void run_child(const wchar_t* args, const char* stdin_bytes, DWORD stdin_delay_ms, child_result* res) {
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);
    wchar_t cmd[2048];
    swprintf(cmd, sizeof cmd / sizeof cmd[0], L"\"%ls\" %ls", self, args);

    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    HANDLE in_r, in_w, out_r, out_w, err_r, err_w;
    CHECK(CreatePipe(&in_r, &in_w, &sa, 0));
    CHECK(CreatePipe(&out_r, &out_w, &sa, 0));
    CHECK(CreatePipe(&err_r, &err_w, &sa, 0));
    SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r;
    si.hStdOutput = out_w;
    si.hStdError = err_w;
    PROCESS_INFORMATION pi;
    CHECK(CreateProcessW(self, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi));
    CloseHandle(in_r);
    CloseHandle(out_w);
    CloseHandle(err_w);

    if (stdin_delay_ms) Sleep(stdin_delay_ms);
    if (stdin_bytes) {
        DWORD wrote = 0;
        WriteFile(in_w, stdin_bytes, (DWORD)strlen(stdin_bytes), &wrote, NULL);
    }
    CloseHandle(in_w);
    read_all_handle(out_r, res->out, sizeof res->out, &res->out_len);
    read_all_handle(err_r, res->err, sizeof res->err, &res->err_len);
    WaitForSingleObject(pi.hProcess, 60000);
    GetExitCodeProcess(pi.hProcess, &res->exit_code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(out_r);
    CloseHandle(err_r);
}

/* What each child case does; its exit status reports its own checks. */
static int child_main(const char* which, int argc, char** argv) {
    if (strcmp(which, "streams") == 0) {
        /* Binary standard streams: "\n" stays "\n", a 0x1A byte passes. */
        LyricString* s = lyric_string_from_literal((const uint8_t*)"a\nb\x1a" "c", 5);
        lyric_console_write_line(1, s);
        lyric_release(s);
        LyricString* e = lyric_string_from_literal((const uint8_t*)"caf\xc3\xa9", 5);
        lyric_console_write(2, e);
        lyric_release(e);
        return 0;
    }
    if (strcmp(which, "panic") == 0) {
        lyric_panic_msg("deliberate", "lyric_win32_test.c", 42);
    }
    if (strcmp(which, "args") == 0) {
        lyric_args_set(argc, argv);
        LyricList* args = lyric_args_get();
        /* program, --child, args, then the UTF-16 argument. */
        int ok = lyric_list_len(args) == 4 &&
                 string_is((LyricString*)(intptr_t)lyric_list_get(args, 3), "\xce\xbb-\xe2\x9c\x93 x");
        lyric_release(args);
        return ok ? 0 : 1;
    }
    if (strcmp(which, "stdin") == 0) {
        /* The parent writes after 300 ms: a short wait times out, a long
         * one sees the line, which then reads without its terminator. */
        int ok = lyric_stdin_wait(50) == 0;
        ok = ok && lyric_stdin_wait(10000) == 1;
        LyricString* line = NULL;
        ok = ok && lyric_stdin_read_line(&line) == 1 && string_is(line, "first");
        if (line) lyric_release(line);
        line = NULL;
        ok = ok && lyric_stdin_read_line(&line) == 1 && string_is(line, "second");
        if (line) lyric_release(line);
        line = NULL;
        ok = ok && lyric_stdin_read_line(&line) == 0; /* end of stream */
        ok = ok && lyric_stdin_wait(0) == 1;          /* a closed pipe is "ready" */
        return ok ? 0 : 1;
    }
    return 2;
}

static void test_standard_streams(void) {
    child_result r;
    run_child(L"--child streams", NULL, 0, &r);
    CHECK(r.exit_code == 0);
    CHECK(r.out_len == 6 && memcmp(r.out, "a\nb\x1a" "c\n", 6) == 0);
    CHECK(r.err_len == 5 && memcmp(r.err, "caf\xc3\xa9", 5) == 0);
}

static void test_panic_exit(void) {
    child_result r;
    run_child(L"--child panic", NULL, 0, &r);
    /* abort()'s status, with no dialog to block the run. */
    CHECK(r.exit_code == 3);
    CHECK(strstr(r.err, "lyric panic at lyric_win32_test.c:42: deliberate") != NULL);
}

static void test_utf16_command_line(void) {
    child_result r;
    run_child(L"--child args \"\x03bb-\x2713 x\"", NULL, 0, &r);
    CHECK(r.exit_code == 0);
}

static void test_stdin_pipe(void) {
    child_result r;
    run_child(L"--child stdin", "first\r\nsecond\n", 300, &r);
    CHECK(r.exit_code == 0);
}

/* ── In-process cases ──────────────────────────────────────────────── */

static void test_unicode_paths(const char* dir) {
    char sub[1024];
    snprintf(sub, sizeof sub, "%s\\\xc3\xbcnicode \xe2\x98\x83/nested\\deeper", dir);
    CHECK(lyric_dir_create_all(sub) == 0);
    CHECK(lyric_dir_exists(sub) == 1);
    CHECK(lyric_dir_create_all(sub) == 0); /* already there */

    char file[1200];
    snprintf(file, sizeof file, "%s\\\xe6\x97\xa5\xe6\x9c\xac.txt", sub);
    LyricString* body = lyric_string_from_literal((const uint8_t*)"x\r\ny\n", 5);
    CHECK(lyric_file_write_all(file, body, 0) == 0);
    lyric_release(body);
    CHECK(lyric_file_exists(file) == 1);
    CHECK(lyric_file_size(file) == 5); /* no newline translation */

    LyricString* back = lyric_file_read_all(file);
    CHECK(string_is(back, "x\r\ny\n"));
    if (back) lyric_release(back);

    int64_t ok = 0;
    LyricList* names = lyric_dir_list_typed(sub, &ok);
    CHECK(ok == 1);
    CHECK(lyric_list_len(names) == 1);
    if (lyric_list_len(names) == 1) {
        CHECK(string_is((LyricString*)(intptr_t)lyric_list_get(names, 0), "2\xe6\x97\xa5\xe6\x9c\xac.txt"));
    }
    lyric_release(names);

    /* The same file through the fd layer, opened by its UTF-8 name. */
    int32_t fd = lyric_open_fd(file, lyric_o_rdonly(), 0);
    CHECK(fd >= 0);
    char buf[8];
    CHECK(lyric_read_fd(fd, buf, sizeof buf) == 5);
    CHECK(lyric_close_fd(fd) == 0);

    int64_t mtime = 0;
    CHECK(lyric_file_mtime_epoch_nanos_ok(file, &mtime) == 0);
    int64_t now = lyric_epoch_nanos();
    CHECK(mtime > now - 600LL * 1000000000LL && mtime <= now + 5LL * 1000000000LL);

    CHECK(lyric_file_delete(file) == 0);
    CHECK(lyric_file_exists(file) == 0);
    CHECK(lyric_dir_remove(sub) == 0);
    snprintf(sub, sizeof sub, "%s\\\xc3\xbcnicode \xe2\x98\x83/nested", dir);
    CHECK(lyric_dir_remove(sub) == 0);
    snprintf(sub, sizeof sub, "%s\\\xc3\xbcnicode \xe2\x98\x83", dir);
    CHECK(lyric_dir_remove(sub) == 0);
}

static void test_rename_replaces(const char* dir) {
    char a[1024];
    char b[1024];
    snprintf(a, sizeof a, "%s\\a.txt", dir);
    snprintf(b, sizeof b, "%s\\b.txt", dir);
    LyricString* one = lyric_string_from_literal((const uint8_t*)"one", 3);
    LyricString* two = lyric_string_from_literal((const uint8_t*)"two", 3);
    CHECK(lyric_file_write_all(a, one, 0) == 0);
    CHECK(lyric_file_write_all(b, two, 0) == 0);
    /* POSIX rename semantics: an existing destination is replaced. */
    CHECK(lyric_file_rename(a, b) == 0);
    LyricString* got = lyric_file_read_all(b);
    CHECK(string_is(got, "one"));
    if (got) lyric_release(got);
    CHECK(lyric_file_exists(a) == 0);
    CHECK(lyric_file_delete(b) == 0);
    lyric_release(one);
    lyric_release(two);
}

static void test_open_flags(const char* dir) {
    char p[1024];
    snprintf(p, sizeof p, "%s\\flags.bin", dir);
    int32_t fd = lyric_open_fd(p, lyric_o_wronly() | lyric_o_creat() | lyric_o_trunc(), 0644);
    CHECK(fd >= 0);
    CHECK(lyric_write_fd(fd, "\n\n", 2) == 2);
    CHECK(lyric_close_fd(fd) == 0);
    fd = lyric_open_fd(p, lyric_o_wronly() | lyric_o_append(), 0);
    CHECK(fd >= 0);
    CHECK(lyric_write_fd(fd, "z", 1) == 1);
    CHECK(lyric_close_fd(fd) == 0);
    CHECK(lyric_file_size(p) == 3);
    /* A closed or negative descriptor fails instead of ending the process. */
    CHECK(lyric_close_fd(fd) == -1);
    CHECK(lyric_close_fd(-1) == -1);
    CHECK(lyric_write_fd(-1, "x", 1) == -1);
    CHECK(lyric_unlink(p) == 0);
    CHECK(lyric_unlink(p) == -1);
}

static void test_environment(void) {
    CHECK(lyric_env_is_windows() == 1);
    CHECK(lyric_env_os_kind() == 3);
    CHECK(lyric_env_arch_kind() == 1 || lyric_env_arch_kind() == 2);
    CHECK(lyric_env_set("LYRIC_WIN32_TEST_VAR", "\xce\xb1\xce\xb2\xce\xb3") == 0);
    LyricString* v = lyric_env_get("LYRIC_WIN32_TEST_VAR");
    CHECK(string_is(v, "\xce\xb1\xce\xb2\xce\xb3"));
    if (v) lyric_release(v);
    /* Set but empty is not unset. */
    CHECK(lyric_env_set("LYRIC_WIN32_TEST_VAR", "") == 0);
    v = lyric_env_get("LYRIC_WIN32_TEST_VAR");
    CHECK(string_is(v, ""));
    if (v) lyric_release(v);
    CHECK(lyric_env_get("LYRIC_WIN32_TEST_UNSET_VAR") == NULL);
    CHECK(lyric_env_set("", "x") == -1);
    CHECK(lyric_env_set("A=B", "x") == -1);

    LyricString* base = NULL;
    CHECK(lyric_env_app_base_directory_ok(&base) == 0);
    CHECK(base != NULL && lyric_string_len(base) > 3 && LYRIC_STRING_DATA(base)[lyric_string_len(base) - 1] == '\\');
    if (base) lyric_release(base);
}

static void test_sleep_precision(void) {
    /* The high-resolution timer, not the 15.6 ms scheduler tick. */
    int64_t best = INT64_MAX;
    for (int i = 0; i < 5; i++) {
        int64_t t0 = lyric_monotonic_nanos();
        lyric_sleep_nanos(2 * 1000000LL);
        int64_t took = lyric_monotonic_nanos() - t0;
        CHECK(took >= 2 * 1000000LL);
        if (took < best) best = took;
    }
    CHECK(best < 12 * 1000000LL);
}

static void test_clocks(void) {
    /* Unix epoch nanoseconds: after 2020-01-01 and consistent with millis. */
    int64_t ns = lyric_epoch_nanos();
    int64_t ms = lyric_epoch_millis();
    CHECK(ns > 1577836800LL * 1000000000LL);
    CHECK(ms - ns / 1000000 >= 0 && ms - ns / 1000000 < 1000);
    int64_t m0 = lyric_monotonic_nanos();
    int64_t m1 = lyric_monotonic_nanos();
    CHECK(m1 >= m0);
}

int main(int argc, char** argv) {
    setvbuf(stderr, NULL, _IONBF, 0);
    if (argc >= 3 && strcmp(argv[1], "--child") == 0) {
        return child_main(argv[2], argc, argv);
    }
    char dir[1024];
    make_temp_dir(dir, sizeof dir);
    test_standard_streams();
    test_panic_exit();
    test_utf16_command_line();
    test_stdin_pipe();
    test_unicode_paths(dir);
    test_rename_replaces(dir);
    test_open_flags(dir);
    test_environment();
    test_sleep_precision();
    test_clocks();
    CHECK(lyric_dir_remove(dir) == 0);
    if (failures == 0) {
        printf("lyric_win32_test: all tests passed\n");
        return 0;
    }
    fprintf(stderr, "lyric_win32_test: %d failure(s)\n", failures);
    return 1;
}
