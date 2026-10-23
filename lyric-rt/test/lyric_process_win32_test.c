/* lyric_process_win32_test.c — tests for the Win32 process layer
 * (src/lyric_process_win32.c, docs/67 G9, #8433): captured runs with stdin
 * and deadlines, inherited runs, the nonblocking capture op, long-lived
 * piped children, argument quoting, program resolution and the handle
 * isolation between concurrent spawns.  They mirror the POSIX twin's
 * test_process_* cases in lyric_rt_test.c.
 *
 * Windows has no /bin/sh, so the children are this executable run again
 * as `--child <mode> ...`; each mode does one small thing (echo, cat, exit,
 * sleep, ...).  Run via `make -C lyric-rt test-windows`.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>

#include "lyric_rt.h"

#include <errno.h>
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

/* ── Child modes ───────────────────────────────────────────────────── */

static void out_bytes(DWORD which, const char* s, size_t n) {
    HANDLE h = GetStdHandle(which);
    while (n > 0) {
        DWORD wrote = 0;
        if (!WriteFile(h, s, (DWORD)n, &wrote, NULL) || wrote == 0) return;
        s += wrote;
        n -= wrote;
    }
}

static void out_str(const char* s) {
    out_bytes(STD_OUTPUT_HANDLE, s, strlen(s));
}

/* Starts this executable as `--child writer` with stdout inherited, and
 * does not wait for it. */
static void start_grandchild_writer(void) {
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);
    wchar_t cmd[MAX_PATH + 32];
    _snwprintf(cmd, sizeof cmd / sizeof cmd[0], L"\"%ls\" --child writer", self);
    cmd[sizeof cmd / sizeof cmd[0] - 1] = L'\0';
    STARTUPINFOW si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = NULL;
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION pi;
    if (CreateProcessW(self, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

/* argv[0] is the program and argv[1] "--child"; the arguments come from
 * the UTF-16 command line, as a Lyric program reads them. */
static int child_main(void) {
    int argc = 0;
    wchar_t** wargv = CommandLineToArgvW(GetCommandLineW(), &argc);
    char** argv = (char**)calloc((size_t)argc + 1, sizeof(char*));
    for (int i = 0; i < argc; i++) {
        int n = WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, NULL, 0, NULL, NULL);
        argv[i] = (char*)malloc((size_t)n);
        WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, argv[i], n, NULL, NULL);
    }
    const char* mode = argc > 2 ? argv[2] : "";
    if (strcmp(mode, "echo") == 0) {
        for (int i = 3; i < argc; i++) {
            if (i > 3) out_str(" ");
            out_str(argv[i]);
        }
        out_str("\n");
        return 0;
    }
    if (strcmp(mode, "args") == 0) {
        /* Each argument followed by a NUL, so any text round-trips. */
        for (int i = 3; i < argc; i++) out_bytes(STD_OUTPUT_HANDLE, argv[i], strlen(argv[i]) + 1);
        return 0;
    }
    if (strcmp(mode, "argv0") == 0) {
        out_str(argv[0]);
        return 0;
    }
    if (strcmp(mode, "cat") == 0) {
        char buf[4096];
        DWORD got = 0;
        while (ReadFile(GetStdHandle(STD_INPUT_HANDLE), buf, sizeof buf, &got, NULL) && got > 0) {
            out_bytes(STD_OUTPUT_HANDLE, buf, got);
        }
        return 0;
    }
    if (strcmp(mode, "exit") == 0) return argc > 3 ? atoi(argv[3]) : 0;
    if (strcmp(mode, "out-err") == 0) {
        out_str("out\n");
        out_bytes(STD_ERROR_HANDLE, "err\n", 4);
        return 0;
    }
    if (strcmp(mode, "stderr") == 0) {
        out_bytes(STD_ERROR_HANDLE, argv[3], strlen(argv[3]));
        return 0;
    }
    if (strcmp(mode, "pre-sleep") == 0) {
        out_str("pre\n");
        Sleep((DWORD)atoi(argv[3]));
        return 0;
    }
    if (strcmp(mode, "sleep") == 0) {
        Sleep((DWORD)atoi(argv[3]));
        return 0;
    }
    if (strcmp(mode, "writer") == 0) {
        for (;;) {
            out_str("g\n");
            Sleep(50);
        }
    }
    if (strcmp(mode, "grandchild-writer") == 0) {
        start_grandchild_writer();
        Sleep(30000);
        return 0;
    }
    if (strcmp(mode, "printf") == 0) {
        out_str(argv[3]);
        return 0;
    }
    if (strcmp(mode, "seq") == 0) {
        int last = atoi(argv[3]);
        char line[16];
        for (int i = 1; i <= last; i++) {
            int n = snprintf(line, sizeof line, "%d\n", i);
            out_bytes(STD_OUTPUT_HANDLE, line, (size_t)n);
        }
        return 0;
    }
    if (strcmp(mode, "split") == 0) {
        out_str("abc");
        Sleep(1000);
        out_str("def\n");
        return 0;
    }
    return 99;
}

/* ── Helpers ───────────────────────────────────────────────────────── */

static char self_path[MAX_PATH * 3];

static LyricString* mk_str(const char* s) {
    return lyric_string_from_literal((const uint8_t*)s, (int64_t)strlen(s));
}

static int str_is(LyricString* s, const char* want) {
    size_t n = strlen(want);
    return s && lyric_string_len(s) == (int64_t)n && memcmp(LYRIC_STRING_DATA(s), want, n) == 0;
}

static void push(LyricList* l, const char* s) {
    LyricString* v = mk_str(s);
    lyric_list_push(l, (int64_t)(intptr_t)v);
    lyric_release(v);
}

/* `--child <mode>` followed by up to three more arguments (NULL ends). */
static LyricList* child_args(const char* mode, const char* a, const char* b, const char* c) {
    LyricList* l = lyric_list_new(1);
    push(l, "--child");
    push(l, mode);
    if (a) push(l, a);
    if (b) push(l, b);
    if (c) push(l, c);
    return l;
}

static LyricString* big_content(int64_t n, char base, uint8_t** out_data) {
    uint8_t* data = (uint8_t*)malloc((size_t)n);
    for (int64_t i = 0; i < n; i++) data[i] = (uint8_t)(base + (i % 26));
    LyricString* s = lyric_string_from_literal(data, n);
    if (out_data) {
        *out_data = data;
    } else {
        free(data);
    }
    return s;
}

static void pump_until_done(void* op, int max_spins) {
    for (int i = 0; i < max_spins && !lyric_process_pump(op); i++) Sleep(1);
}

/* ── Captured runs ─────────────────────────────────────────────────── */

static void test_run_basic(void) {
    LyricList* args = child_args("echo", "hello", "world", NULL);
    int32_t code = -99;
    LyricString* out = NULL;
    LyricString* err = NULL;
    CHECK(lyric_process_run(self_path, args, NULL, -1, &code, &out, &err, NULL) == 0);
    CHECK(code == 0);
    CHECK(str_is(out, "hello world\n"));
    CHECK(str_is(err, ""));
    lyric_release(out);
    lyric_release(err);
    lyric_release(args);

    LyricList* oe = child_args("out-err", NULL, NULL, NULL);
    CHECK(lyric_process_run(self_path, oe, NULL, -1, &code, &out, &err, NULL) == 0);
    CHECK(str_is(out, "out\n"));
    CHECK(str_is(err, "err\n"));
    lyric_release(out);
    lyric_release(err);
    lyric_release(oe);

    /* A program that really exits 127 reports 127; a missing program is a
     * spawn failure with ENOENT. */
    LyricList* e127 = child_args("exit", "127", NULL, NULL);
    CHECK(lyric_process_run(self_path, e127, NULL, -1, &code, &out, &err, NULL) == 0);
    CHECK(code == 127);
    lyric_release(out);
    lyric_release(err);
    lyric_release(e127);
    CHECK(lyric_process_run("C:\\nonexistent-lyric-rt-test.exe", NULL, NULL, -1, &code, &out, &err, NULL) == -1);
    CHECK(lyric_process_last_spawn_errno() == ENOENT);
    LyricString* msg = lyric_process_errno_message(ENOENT);
    CHECK(lyric_string_len(msg) > 0);
    lyric_release(msg);
}

static void test_run_quoting(void) {
    static const char* const tricky[] = {
        "",
        "plain",
        "two words",
        "a\"b",
        "\"",
        "trailing\\",
        "trailing\\\\",
        "\\\"",
        "C:\\Program Files\\x\\",
        "back\\\\slash \\\"quote\"",
        "tab\there",
        "new\nline",
        "\xc3\xa9t\xc3\xa9",
        "\xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x8e\xb5",
        "a\\b c",
        "%PATH%",
        "^&|<>",
    };
    size_t n = sizeof tricky / sizeof tricky[0];
    LyricList* args = lyric_list_new(1);
    push(args, "--child");
    push(args, "args");
    size_t expect_len = 0;
    for (size_t i = 0; i < n; i++) {
        push(args, tricky[i]);
        expect_len += strlen(tricky[i]) + 1;
    }
    int32_t code = -99;
    LyricString* out = NULL;
    LyricString* err = NULL;
    CHECK(lyric_process_run(self_path, args, NULL, -1, &code, &out, &err, NULL) == 0);
    CHECK(code == 0);
    CHECK(lyric_string_len(out) == (int64_t)expect_len);
    if (lyric_string_len(out) == (int64_t)expect_len) {
        const char* p = (const char*)LYRIC_STRING_DATA(out);
        for (size_t i = 0; i < n; i++) {
            CHECK(strcmp(p, tricky[i]) == 0);
            p += strlen(tricky[i]) + 1;
        }
    }
    lyric_release(out);
    lyric_release(err);
    lyric_release(args);

    /* A NUL byte cannot cross a command line: the spawn fails with EINVAL. */
    LyricList* bad = lyric_list_new(1);
    LyricString* nul = lyric_string_from_literal((const uint8_t*)"a\0b", 3);
    lyric_list_push(bad, (int64_t)(intptr_t)nul);
    lyric_release(nul);
    CHECK(lyric_process_run(self_path, bad, NULL, -1, &code, &out, &err, NULL) == -1);
    CHECK(lyric_process_last_spawn_errno() == EINVAL);
    lyric_release(bad);
}

/* Writes `text` to `path` (UTF-8 path). */
static void write_file(const char* path, const char* text) {
    LyricString* t = mk_str(text);
    CHECK(lyric_file_write_all(path, t, 0) == 0);
    lyric_release(t);
}

static void make_temp_dir(char* out, size_t cap, const char* suffix) {
    wchar_t base[MAX_PATH + 1];
    DWORD n = GetTempPathW(MAX_PATH + 1, base);
    CHECK(n > 0);
    uint8_t r[4];
    CHECK(lyric_secure_random(r, 4) == 0);
    char tmp[MAX_PATH * 3];
    WideCharToMultiByte(CP_UTF8, 0, base, -1, tmp, (int)sizeof tmp, NULL, NULL);
    snprintf(out, cap, "%slyric_proc_test_%02x%02x%02x%02x%s", tmp, r[0], r[1], r[2], r[3], suffix);
    CHECK(lyric_dir_create(out) == 0);
}

static int copy_utf8(const char* from, const char* to) {
    wchar_t wf[MAX_PATH * 2];
    wchar_t wt[MAX_PATH * 2];
    MultiByteToWideChar(CP_UTF8, 0, from, -1, wf, MAX_PATH * 2);
    MultiByteToWideChar(CP_UTF8, 0, to, -1, wt, MAX_PATH * 2);
    return CopyFileW(wf, wt, FALSE) ? 0 : -1;
}

static void test_run_resolution(void) {
    char dir[MAX_PATH * 3];
    make_temp_dir(dir, sizeof dir, "_\xc3\xa9\xe6\x97\xa5");

    /* A program under a non-ASCII directory, named without ".exe". */
    char copy[MAX_PATH * 3];
    snprintf(copy, sizeof copy, "%s\\helper.exe", dir);
    CHECK(copy_utf8(self_path, copy) == 0);
    char no_ext[MAX_PATH * 3];
    snprintf(no_ext, sizeof no_ext, "%s\\helper", dir);
    LyricList* args = child_args("argv0", NULL, NULL, NULL);
    int32_t code = -99;
    LyricString* out = NULL;
    LyricString* err = NULL;
    CHECK(lyric_process_run(no_ext, args, NULL, -1, &code, &out, &err, NULL) == 0);
    CHECK(code == 0);
    CHECK(str_is(out, no_ext)); /* argv[0] is the path as given */
    lyric_release(out);
    lyric_release(err);

    /* A bare name is looked up on PATH, never in the current directory. */
    wchar_t old_path[32767];
    DWORD had = GetEnvironmentVariableW(L"PATH", old_path, 32767);
    wchar_t wdir[MAX_PATH * 2];
    MultiByteToWideChar(CP_UTF8, 0, dir, -1, wdir, MAX_PATH * 2);
    wchar_t new_path[32767 + MAX_PATH * 2];
    _snwprintf(new_path, sizeof new_path / sizeof new_path[0], L"C:\\nonexistent-dir;\"%ls\";%ls", wdir,
               had ? old_path : L"");
    new_path[sizeof new_path / sizeof new_path[0] - 1] = L'\0';
    CHECK(SetEnvironmentVariableW(L"PATH", new_path));
    CHECK(lyric_process_run("helper", args, NULL, -1, &code, &out, &err, NULL) == 0);
    CHECK(code == 0);
    lyric_release(out);
    lyric_release(err);
    SetEnvironmentVariableW(L"PATH", had ? old_path : NULL);

    wchar_t old_cwd[MAX_PATH * 2];
    GetCurrentDirectoryW(MAX_PATH * 2, old_cwd);
    CHECK(SetCurrentDirectoryW(wdir));
    CHECK(lyric_process_run("helper", args, NULL, -1, &code, &out, &err, NULL) == -1);
    CHECK(lyric_process_last_spawn_errno() == ENOENT);
    SetCurrentDirectoryW(old_cwd);

    /* A batch file would run through cmd.exe: refused. */
    char bat[MAX_PATH * 3];
    snprintf(bat, sizeof bat, "%s\\script.cmd", dir);
    write_file(bat, "@echo hi\r\n");
    CHECK(lyric_process_run(bat, NULL, NULL, -1, &code, &out, &err, NULL) == -1);
    CHECK(lyric_process_last_spawn_errno() == ENOEXEC);

    /* A directory is not a program. */
    CHECK(lyric_process_run(dir, NULL, NULL, -1, &code, &out, &err, NULL) == -1);
    CHECK(lyric_process_last_spawn_errno() == ENOENT);
    lyric_release(args);

    CHECK(lyric_file_delete(copy) == 0);
    CHECK(lyric_file_delete(bat) == 0);
    CHECK(lyric_dir_remove(dir) == 0);
}

static void test_run_inherited(void) {
    LyricList* args = child_args("exit", "7", NULL, NULL);
    int32_t code = -99;
    CHECK(lyric_process_run_inherited(self_path, args, &code) == 0);
    CHECK(code == 7);
    lyric_release(args);

    int32_t code2 = -99;
    CHECK(lyric_process_run_inherited("C:\\nonexistent-lyric-rt-test.exe", NULL, &code2) == -1);
    CHECK(code2 == -99);
    CHECK(lyric_process_last_spawn_errno() == ENOENT);
}

static void test_run_stdin(void) {
    LyricList* cat = child_args("cat", NULL, NULL, NULL);
    LyricString* content = mk_str("in-out");
    int32_t code = -1;
    int32_t timed_out = -1;
    LyricString* out = NULL;
    LyricString* err = NULL;
    CHECK(lyric_process_run(self_path, cat, content, -1, &code, &out, &err, &timed_out) == 0);
    CHECK(code == 0);
    CHECK(timed_out == 0);
    CHECK(str_is(out, "in-out"));
    lyric_release(content);
    lyric_release(out);
    lyric_release(err);

    /* 256 KiB each way: well past the pipe buffers, so this deadlocks
     * unless stdin writes interleave with stdout reads. */
    int64_t big = 256 * 1024;
    uint8_t* data = NULL;
    LyricString* bigs = big_content(big, 'a', &data);
    CHECK(lyric_process_run(self_path, cat, bigs, 30000, &code, &out, &err, &timed_out) == 0);
    CHECK(code == 0);
    CHECK(timed_out == 0);
    CHECK(lyric_string_len(out) == big);
    CHECK(lyric_string_len(out) == big && memcmp(LYRIC_STRING_DATA(out), data, (size_t)big) == 0);
    lyric_release(out);
    lyric_release(err);
    lyric_release(cat);

    /* A child that exits without reading: the rest is dropped, the real
     * status kept. */
    LyricList* ex = child_args("exit", "3", NULL, NULL);
    CHECK(lyric_process_run(self_path, ex, bigs, 30000, &code, &out, &err, &timed_out) == 0);
    CHECK(code == 3);
    CHECK(timed_out == 0);
    lyric_release(out);
    lyric_release(err);
    lyric_release(ex);
    lyric_release(bigs);
    free(data);
}

static void test_run_timeout(void) {
    LyricList* args = child_args("pre-sleep", "30000", NULL, NULL);
    int32_t code = -1;
    int32_t timed_out = -1;
    LyricString* out = NULL;
    LyricString* err = NULL;
    int64_t t0 = lyric_monotonic_nanos();
    CHECK(lyric_process_run(self_path, args, NULL, 300, &code, &out, &err, &timed_out) == 0);
    int64_t elapsed_ms = (lyric_monotonic_nanos() - t0) / 1000000;
    CHECK(timed_out == 1);
    CHECK(code == 137);
    CHECK(str_is(out, "pre\n"));
    CHECK(elapsed_ms < 10000);
    lyric_release(out);
    lyric_release(err);
    lyric_release(args);

    /* A deadline with stdin still being fed (#5175). */
    LyricList* sl = child_args("sleep", "30000", NULL, NULL);
    LyricString* bigs = big_content(256 * 1024, 'y', NULL);
    t0 = lyric_monotonic_nanos();
    CHECK(lyric_process_run(self_path, sl, bigs, 300, &code, &out, &err, &timed_out) == 0);
    elapsed_ms = (lyric_monotonic_nanos() - t0) / 1000000;
    CHECK(timed_out == 1);
    CHECK(code == 137);
    CHECK(lyric_string_len(out) == 0);
    CHECK(elapsed_ms < 10000);
    lyric_release(out);
    lyric_release(err);
    lyric_release(sl);
    lyric_release(bigs);

    /* The job takes the grandchild that holds stdout too, so the drain ends
     * on end of stream, well inside the 2 s budget (D-N-025, #5176). */
    LyricList* gw = child_args("grandchild-writer", NULL, NULL, NULL);
    t0 = lyric_monotonic_nanos();
    CHECK(lyric_process_run(self_path, gw, NULL, 300, &code, &out, &err, &timed_out) == 0);
    elapsed_ms = (lyric_monotonic_nanos() - t0) / 1000000;
    CHECK(timed_out == 1);
    CHECK(code == 137);
    CHECK(elapsed_ms < 2000);
    lyric_release(out);
    lyric_release(err);
    lyric_release(gw);

    /* A child that finishes before the deadline is not a timeout. */
    LyricList* quick = child_args("exit", "4", NULL, NULL);
    CHECK(lyric_process_run(self_path, quick, NULL, 10000, &code, &out, &err, &timed_out) == 0);
    CHECK(code == 4);
    CHECK(timed_out == 0);
    lyric_release(out);
    lyric_release(err);
    lyric_release(quick);
}

/* ── The nonblocking op ────────────────────────────────────────────── */

static void test_op(void) {
    LyricList* args = child_args("echo", "pump", NULL, NULL);
    void* op = lyric_process_start(self_path, args, NULL);
    lyric_release(args);
    CHECK(!lyric_process_spawn_failed(op));
    pump_until_done(op, 10000);
    CHECK(lyric_process_pump(op) == 1);
    CHECK(lyric_process_exit_code(op) == 0);
    LyricString* out = lyric_process_stdout(op);
    LyricString* errs = lyric_process_stderr(op);
    CHECK(str_is(out, "pump\n"));
    CHECK(str_is(errs, ""));
    lyric_release(out);
    lyric_release(errs);
    /* Kill after a natural exit is not a kill (#5107). */
    CHECK(lyric_process_kill(op) == 0);
    CHECK(lyric_process_exit_code(op) == 0);
    lyric_process_free(op);

    /* Killed mid-run: partial output kept, killed status. */
    LyricList* ps = child_args("pre-sleep", "30000", NULL, NULL);
    void* op2 = lyric_process_start(self_path, ps, NULL);
    lyric_release(ps);
    CHECK(!lyric_process_spawn_failed(op2));
    for (int i = 0; i < 10000; i++) {
        lyric_process_pump(op2);
        LyricString* probe = lyric_process_stdout(op2);
        int64_t got = lyric_string_len(probe);
        lyric_release(probe);
        if (got >= 4) break;
        Sleep(1);
    }
    CHECK(!lyric_process_pump(op2));
    CHECK(lyric_process_kill(op2) == 1);
    CHECK(lyric_process_pump(op2) == 1);
    CHECK(lyric_process_exit_code(op2) == 137);
    LyricString* out2 = lyric_process_stdout(op2);
    CHECK(str_is(out2, "pre\n"));
    lyric_release(out2);
    lyric_process_free(op2);

    /* A missing program: born done and failed. */
    void* op3 = lyric_process_start("C:\\nonexistent-lyric-op.exe", NULL, NULL);
    CHECK(lyric_process_spawn_failed(op3));
    CHECK(lyric_process_pump(op3) == 1);
    CHECK(lyric_process_exit_code(op3) == -1);
    lyric_process_free(op3);

    /* 256 KiB of stdin through start/pump alone. */
    int64_t big = 256 * 1024;
    uint8_t* data = NULL;
    LyricString* bigs = big_content(big, 'A', &data);
    LyricList* cat = child_args("cat", NULL, NULL, NULL);
    void* op4 = lyric_process_start(self_path, cat, bigs);
    lyric_release(bigs);
    lyric_release(cat);
    CHECK(!lyric_process_spawn_failed(op4));
    pump_until_done(op4, 30000);
    CHECK(lyric_process_pump(op4) == 1);
    CHECK(lyric_process_exit_code(op4) == 0);
    LyricString* out4 = lyric_process_stdout(op4);
    CHECK(lyric_string_len(out4) == big && memcmp(LYRIC_STRING_DATA(out4), data, (size_t)big) == 0);
    lyric_release(out4);
    lyric_process_free(op4);
    free(data);
}

/* ── Piped children ────────────────────────────────────────────────── */

static void test_piped_roundtrip(void) {
    LyricList* cat = child_args("cat", NULL, NULL, NULL);
    void* p = lyric_process_piped_spawn(self_path, cat);
    lyric_release(cat);
    CHECK(p != NULL);
    if (!p) return;
    CHECK(lyric_process_piped_is_alive(p) == 1);
    LyricString* l1 = mk_str("hello");
    CHECK(lyric_process_piped_write_line(p, l1) == 0);
    lyric_release(l1);
    LyricString* got = NULL;
    CHECK(lyric_process_piped_read_line(p, &got) == 1);
    CHECK(str_is(got, "hello"));
    lyric_release(got);
    LyricString* l2 = mk_str("world again \xc3\xa9");
    CHECK(lyric_process_piped_write_line(p, l2) == 0);
    lyric_release(l2);
    CHECK(lyric_process_piped_read_line(p, &got) == 1);
    CHECK(str_is(got, "world again \xc3\xa9"));
    lyric_release(got);
    CHECK(lyric_process_piped_close_stdin(p) == 0);
    LyricString* l3 = mk_str("after close");
    CHECK(lyric_process_piped_write_line(p, l3) == -2);
    lyric_release(l3);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    CHECK(lyric_process_piped_exit_code(p) == 0);
    CHECK(lyric_process_piped_is_alive(p) == 0);
    CHECK(lyric_process_piped_read_line(p, &got) == 0);
    lyric_process_piped_close(p);
    lyric_process_piped_close(p); /* idempotent (#6975) */
}

static void test_piped_lines(void) {
    /* A final line with no newline is returned once, then end of stream. */
    LyricList* pf = child_args("printf", "trailing", NULL, NULL);
    void* p = lyric_process_piped_spawn(self_path, pf);
    lyric_release(pf);
    CHECK(p != NULL);
    LyricString* got = NULL;
    CHECK(lyric_process_piped_read_line(p, &got) == 1);
    CHECK(str_is(got, "trailing"));
    lyric_release(got);
    CHECK(lyric_process_piped_read_line(p, &got) == 0);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    lyric_process_piped_close(p);

    /* CRLF endings lose the CR. */
    LyricList* crlf = child_args("printf", "a\r\nb\n", NULL, NULL);
    p = lyric_process_piped_spawn(self_path, crlf);
    lyric_release(crlf);
    CHECK(p != NULL);
    CHECK(lyric_process_piped_read_line(p, &got) == 1);
    CHECK(str_is(got, "a"));
    lyric_release(got);
    CHECK(lyric_process_piped_read_line(p, &got) == 1);
    CHECK(str_is(got, "b"));
    lyric_release(got);
    CHECK(lyric_process_piped_read_line(p, &got) == 0);
    lyric_process_piped_close(p);

    /* 5000 lines in one burst, in order (#7277). */
    LyricList* seq = child_args("seq", "5000", NULL, NULL);
    p = lyric_process_piped_spawn(self_path, seq);
    lyric_release(seq);
    CHECK(p != NULL);
    int ok = 1;
    char expect[16];
    for (int n = 1; n <= 5000 && ok; n++) {
        if (lyric_process_piped_read_line(p, &got) != 1) {
            ok = 0;
            break;
        }
        snprintf(expect, sizeof expect, "%d", n);
        if (!str_is(got, expect)) ok = 0;
        lyric_release(got);
    }
    CHECK(ok);
    CHECK(lyric_process_piped_read_line(p, &got) == 0);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    lyric_process_piped_close(p);

    /* Closed with a second line still buffered (#6993): the next read
     * reports end of stream instead of touching freed memory. */
    LyricList* two = child_args("printf", "a\nb\n", NULL, NULL);
    p = lyric_process_piped_spawn(self_path, two);
    lyric_release(two);
    CHECK(p != NULL);
    CHECK(lyric_process_piped_read_line(p, &got) == 1);
    lyric_release(got);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    lyric_process_piped_close(p);
    CHECK(lyric_process_piped_read_line(p, &got) == 0);
}

static void test_piped_read_line_within(void) {
    LyricList* cat = child_args("cat", NULL, NULL, NULL);
    void* p = lyric_process_piped_spawn(self_path, cat);
    CHECK(p != NULL);
    LyricString* none = NULL;
    int64_t t0 = lyric_monotonic_nanos();
    CHECK(lyric_process_piped_read_line_within(p, &none, 100) == 2);
    int64_t waited_ms = (lyric_monotonic_nanos() - t0) / 1000000;
    CHECK(waited_ms >= 90);
    CHECK(waited_ms < 5000);
    CHECK(lyric_process_piped_read_line_within(p, &none, 0) == 2);
    LyricString* late = mk_str("late");
    CHECK(lyric_process_piped_write_line(p, late) == 0);
    lyric_release(late);
    LyricString* got = NULL;
    CHECK(lyric_process_piped_read_line_within(p, &got, 5000) == 1);
    CHECK(str_is(got, "late"));
    lyric_release(got);
    CHECK(lyric_process_piped_close_stdin(p) == 0);
    CHECK(lyric_process_piped_read_line_within(p, &got, 5000) == 0);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    lyric_process_piped_close(p);

    /* A line split across the deadline is joined by the next read. */
    LyricList* split = child_args("split", NULL, NULL, NULL);
    void* q = lyric_process_piped_spawn(self_path, split);
    lyric_release(split);
    CHECK(q != NULL);
    CHECK(lyric_process_piped_read_line_within(q, &none, 300) == 2);
    CHECK(lyric_process_piped_read_line_within(q, &got, 10000) == 1);
    CHECK(str_is(got, "abcdef"));
    lyric_release(got);
    CHECK(lyric_process_piped_wait_exit(q, 5000) == 1);
    lyric_process_piped_close(q);

    /* #7523: a zero budget still returns a line already in the pipe. */
    void* r = lyric_process_piped_spawn(self_path, cat);
    lyric_release(cat);
    CHECK(r != NULL);
    LyricString* ready = mk_str("ready");
    CHECK(lyric_process_piped_write_line(r, ready) == 0);
    lyric_release(ready);
    int rc = 2;
    for (int i = 0; i < 500 && rc == 2; i++) {
        rc = lyric_process_piped_read_line_within(r, &got, 0);
        if (rc == 2) Sleep(10);
    }
    CHECK(rc == 1);
    if (rc == 1) {
        CHECK(str_is(got, "ready"));
        lyric_release(got);
    }
    CHECK(lyric_process_piped_read_line_within(r, &none, 0) == 2);
    CHECK(lyric_process_piped_close_stdin(r) == 0);
    CHECK(lyric_process_piped_wait_exit(r, 5000) == 1);
    lyric_process_piped_close(r);
}

static void test_piped_kill_and_failure(void) {
    LyricList* sl = child_args("sleep", "30000", NULL, NULL);
    void* p = lyric_process_piped_spawn(self_path, sl);
    lyric_release(sl);
    CHECK(p != NULL);
    CHECK(lyric_process_piped_is_alive(p) == 1);
    CHECK(lyric_process_piped_wait_exit(p, 50) == 0);
    CHECK(lyric_process_piped_kill(p) == 0);
    CHECK(lyric_process_piped_is_alive(p) == 0);
    CHECK(lyric_process_piped_exit_code(p) == 137);
    CHECK(lyric_process_piped_kill(p) == 0);
    /* A write to a dead child fails instead of blocking. */
    LyricString* line = mk_str("x");
    CHECK(lyric_process_piped_write_line(p, line) == -1);
    lyric_release(line);
    lyric_process_piped_close(p);

    CHECK(lyric_process_piped_spawn("C:\\nonexistent-lyric-rt-piped.exe", NULL) == NULL);
    CHECK(lyric_process_last_spawn_errno() == ENOENT);
}

static void test_piped_stderr_inherited(void) {
    /* stderr is never piped: the child's goes wherever ours does. */
    char dir[MAX_PATH * 3];
    make_temp_dir(dir, sizeof dir, "");
    char path[MAX_PATH * 3];
    snprintf(path, sizeof path, "%s\\stderr.txt", dir);
    wchar_t wpath[MAX_PATH * 2];
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, MAX_PATH * 2);
    HANDLE f = CreateFileW(wpath, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    CHECK(f != INVALID_HANDLE_VALUE);
    HANDLE saved = GetStdHandle(STD_ERROR_HANDLE);
    SetStdHandle(STD_ERROR_HANDLE, f);
    LyricList* args = child_args("stderr", "err-side", NULL, NULL);
    void* p = lyric_process_piped_spawn(self_path, args);
    lyric_release(args);
    SetStdHandle(STD_ERROR_HANDLE, saved);
    CHECK(p != NULL);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    CHECK(lyric_process_piped_exit_code(p) == 0);
    LyricString* got = NULL;
    CHECK(lyric_process_piped_read_line(p, &got) == 0);
    lyric_process_piped_close(p);
    CloseHandle(f);
    LyricString* text = NULL;
    CHECK(lyric_file_read_all_ok(path, &text) == 0);
    CHECK(str_is(text, "err-side"));
    if (text) lyric_release(text);
    CHECK(lyric_file_delete(path) == 0);
    CHECK(lyric_dir_remove(dir) == 0);
}

/* Children started at the same time from several threads each see end of
 * stream on stdin as soon as their own parent closes it: none holds a pipe
 * end that belongs to a sibling. */
static volatile LONG concurrent_failures = 0;

static void* concurrent_worker(void* arg) {
    (void)arg;
    for (int i = 0; i < 8; i++) {
        LyricList* cat = child_args("cat", NULL, NULL, NULL);
        void* p = lyric_process_piped_spawn(self_path, cat);
        lyric_release(cat);
        if (!p) {
            InterlockedIncrement(&concurrent_failures);
            continue;
        }
        LyricString* line = mk_str("ping");
        LyricString* got = NULL;
        if (lyric_process_piped_write_line(p, line) != 0 || lyric_process_piped_read_line_within(p, &got, 10000) != 1 ||
            !str_is(got, "ping")) {
            InterlockedIncrement(&concurrent_failures);
        }
        lyric_release(line);
        if (got) lyric_release(got);
        lyric_process_piped_close_stdin(p);
        if (lyric_process_piped_wait_exit(p, 10000) != 1) {
            InterlockedIncrement(&concurrent_failures);
            lyric_process_piped_kill(p);
        }
        lyric_process_piped_close(p);
    }
    return NULL;
}

static void test_concurrent_spawns(void) {
    int64_t tids[4];
    for (int i = 0; i < 4; i++) CHECK(lyric_thread_create(&tids[i], concurrent_worker, NULL) == 0);
    for (int i = 0; i < 4; i++) CHECK(lyric_thread_join(tids[i], NULL) == 0);
    CHECK(concurrent_failures == 0);
}

int main(int argc, char** argv) {
    if (argc > 1 && strcmp(argv[1], "--child") == 0) return child_main();
    /* A child whose arguments went astray must not run the suite again (and
     * start children of its own). */
    if (GetEnvironmentVariableW(L"LYRIC_PROCESS_TEST_PARENT", NULL, 0) > 0) {
        fprintf(stderr, "lyric_process_win32_test: child started without --child\n");
        return 98;
    }
    SetEnvironmentVariableW(L"LYRIC_PROCESS_TEST_PARENT", L"1");
    wchar_t wself[MAX_PATH];
    GetModuleFileNameW(NULL, wself, MAX_PATH);
    WideCharToMultiByte(CP_UTF8, 0, wself, -1, self_path, (int)sizeof self_path, NULL, NULL);

    test_run_basic();
    test_run_quoting();
    test_run_resolution();
    test_run_inherited();
    test_run_stdin();
    test_run_timeout();
    test_op();
    test_piped_roundtrip();
    test_piped_lines();
    test_piped_read_line_within();
    test_piped_kill_and_failure();
    test_piped_stderr_inherited();
    test_concurrent_spawns();

    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("lyric_process_win32_test: all tests passed\n");
    return 0;
}
