/* lyric_rt_test.c — unit tests for the lyric-rt runtime (N0.4).
 * Run via `make -C lyric-rt test`.  Exits non-zero on the first failure.
 */
#if defined(__linux__)
/* mkstemp/mkdtemp need POSIX.1-2008 / XSI visibility under -std=c11. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                    \
        }                                                                  \
    } while (0)

/* Counting destructor used by the ARC tests. */
static int dtor_calls = 0;
static void counting_dtor(void* obj) {
    (void)obj;
    dtor_calls++;
}

static void test_alloc_retain_release(void) {
    CHECK(lyric_alloc(16) != NULL);

    /* NULL is a no-op for both. */
    lyric_retain(NULL);
    lyric_release(NULL);

    /* rc lifecycle: 1 -> 2 -> 1 -> 0 (dtor fires exactly once). */
    LyricObjectHeader* h = (LyricObjectHeader*)lyric_alloc(sizeof(LyricObjectHeader));
    atomic_store(&h->rc, 1);
    h->dtor = counting_dtor;
    dtor_calls = 0;
    lyric_retain(h);
    lyric_release(h);
    CHECK(dtor_calls == 0);
    lyric_release(h);
    CHECK(dtor_calls == 1);

    /* Static sentinel: neither retain nor release may touch it. */
    LyricObjectHeader stat;
    atomic_store(&stat.rc, INT32_MAX);
    stat.dtor = counting_dtor;
    dtor_calls = 0;
    lyric_retain(&stat);
    lyric_release(&stat);
    CHECK(atomic_load(&stat.rc) == INT32_MAX);
    CHECK(dtor_calls == 0);
}

static void test_strings(void) {
    LyricString* a = lyric_string_from_literal((const uint8_t*)"hello", 5);
    LyricString* b = lyric_string_from_literal((const uint8_t*)", world", 7);
    CHECK(lyric_string_len(a) == 5);
    CHECK(lyric_string_byte_at(a, 0) == 'h');
    CHECK(lyric_string_byte_at(a, 4) == 'o');

    LyricString* ab = lyric_string_concat(a, b);
    CHECK(lyric_string_len(ab) == 12);
    CHECK(memcmp(LYRIC_STRING_DATA(ab), "hello, world", 12) == 0);

    LyricString* a2 = lyric_string_from_literal((const uint8_t*)"hello", 5);
    CHECK(lyric_string_eq(a, a2));
    CHECK(!lyric_string_eq(a, b));
    CHECK(lyric_string_cmp(a, b) > 0);  /* "hello" > ", world" */
    CHECK(lyric_string_cmp(a, a2) == 0);

    LyricString* sub = lyric_string_substring(ab, 7, 5);
    CHECK(lyric_string_len(sub) == 5);
    CHECK(memcmp(LYRIC_STRING_DATA(sub), "world", 5) == 0);

    LyricString* i = lyric_string_from_int(-42);
    CHECK(lyric_string_len(i) == 3);
    CHECK(memcmp(LYRIC_STRING_DATA(i), "-42", 3) == 0);

    LyricString* f = lyric_string_from_float(2.5);
    CHECK(lyric_string_len(f) == 3);
    CHECK(memcmp(LYRIC_STRING_DATA(f), "2.5", 3) == 0);

    /* Non-finite values use the managed targets' canonical spellings. */
    LyricString* fnan = lyric_string_from_float(0.0 / 0.0);
    CHECK(lyric_string_len(fnan) == 3);
    CHECK(memcmp(LYRIC_STRING_DATA(fnan), "NaN", 3) == 0);
    LyricString* finf = lyric_string_from_float(1.0 / 0.0);
    CHECK(lyric_string_len(finf) == 8);
    CHECK(memcmp(LYRIC_STRING_DATA(finf), "Infinity", 8) == 0);
    LyricString* fninf = lyric_string_from_float(-1.0 / 0.0);
    CHECK(lyric_string_len(fninf) == 9);
    CHECK(memcmp(LYRIC_STRING_DATA(fninf), "-Infinity", 9) == 0);

    LyricString* t = lyric_string_from_bool(1);
    CHECK(memcmp(LYRIC_STRING_DATA(t), "true", 4) == 0);

    /* U+00E9 (e-acute) encodes as two UTF-8 bytes. */
    LyricString* ch = lyric_string_from_char(0xE9);
    CHECK(lyric_string_len(ch) == 2);
    CHECK(LYRIC_STRING_DATA(ch)[0] == 0xC3 && LYRIC_STRING_DATA(ch)[1] == 0xA9);

    const char* cs = lyric_string_to_cstring(ab);
    CHECK(strcmp(cs, "hello, world") == 0);
    lyric_cstring_free(cs);

    lyric_release(a);
    lyric_release(a2);
    lyric_release(b);
    lyric_release(ab);
    lyric_release(sub);
    lyric_release(i);
    lyric_release(f);
    lyric_release(fnan);
    lyric_release(finf);
    lyric_release(fninf);
    lyric_release(t);
    lyric_release(ch);
}

static void test_weak(void) {
    LyricObjectHeader* h = (LyricObjectHeader*)lyric_alloc(sizeof(LyricObjectHeader));
    atomic_store(&h->rc, 1);
    h->dtor = counting_dtor;

    /* Alive: upgrade succeeds and bumps rc. */
    void* up = lyric_weak_upgrade(h);
    CHECK(up == h);
    CHECK(atomic_load(&h->rc) == 2);
    lyric_release(h);

    /* Simulated death: rc drops to 0 (without freeing, so the header
     * stays readable for the test) — upgrade must return NULL. */
    dtor_calls = 0;
    atomic_store(&h->rc, 0);
    CHECK(lyric_weak_upgrade(h) == NULL);
    CHECK(lyric_weak_upgrade(NULL) == NULL);
    free(h);
}

static void test_list_scalars(void) {
    LyricList* l = lyric_list_new(0);
    CHECK(lyric_list_len(l) == 0);
    for (int64_t i = 0; i < 100; i++) lyric_list_push(l, i * 3);
    CHECK(lyric_list_len(l) == 100);
    CHECK(lyric_list_get(l, 0) == 0);
    CHECK(lyric_list_get(l, 99) == 297);
    lyric_list_set(l, 50, -1);
    CHECK(lyric_list_get(l, 50) == -1);
    lyric_list_remove_at(l, 0);
    CHECK(lyric_list_len(l) == 99);
    CHECK(lyric_list_get(l, 0) == 3);
    lyric_list_clear(l);
    CHECK(lyric_list_len(l) == 0);
    lyric_release(l);
}

static void test_list_refs(void) {
    LyricList* l = lyric_list_new(1);
    LyricString* s = lyric_string_from_literal((const uint8_t*)"elem", 4);
    CHECK(atomic_load(&s->rc) == 1);
    lyric_list_push(l, (int64_t)(intptr_t)s);
    CHECK(atomic_load(&s->rc) == 2); /* list retained it */
    lyric_release(l);                /* dtor releases the element */
    CHECK(atomic_load(&s->rc) == 1);
    lyric_release(s);
}

static void test_map_int_keys(void) {
    LyricMap* m = lyric_map_new(0, 0);
    CHECK(lyric_map_len(m) == 0);
    for (int64_t i = 0; i < 1000; i++) lyric_map_set(m, i, i * i);
    CHECK(lyric_map_len(m) == 1000);
    int64_t v = 0;
    CHECK(lyric_map_get(m, 31, &v) && v == 961);
    CHECK(!lyric_map_get(m, 5000, &v));
    CHECK(lyric_map_contains(m, 999));
    lyric_map_set(m, 31, 7); /* overwrite */
    CHECK(lyric_map_len(m) == 1000);
    CHECK(lyric_map_get(m, 31, &v) && v == 7);
    CHECK(lyric_map_remove(m, 31));
    CHECK(!lyric_map_remove(m, 31));
    CHECK(lyric_map_len(m) == 999);
    CHECK(!lyric_map_contains(m, 31));
    /* Reinsert after tombstone. */
    lyric_map_set(m, 31, 8);
    CHECK(lyric_map_get(m, 31, &v) && v == 8);
    lyric_release(m);
}

static void test_map_string_keys(void) {
    LyricMap* m = lyric_map_new(1, 1);
    LyricString* k1 = lyric_string_from_literal((const uint8_t*)"alpha", 5);
    LyricString* k1b = lyric_string_from_literal((const uint8_t*)"alpha", 5);
    LyricString* v1 = lyric_string_from_literal((const uint8_t*)"one", 3);
    lyric_map_set(m, (int64_t)(intptr_t)k1, (int64_t)(intptr_t)v1);
    CHECK(atomic_load(&k1->rc) == 2); /* map retained the key   */
    CHECK(atomic_load(&v1->rc) == 2); /* ... and the value      */

    /* Structural key equality: a different allocation with the same
     * bytes finds the entry. */
    int64_t got = 0;
    CHECK(lyric_map_get(m, (int64_t)(intptr_t)k1b, &got));
    CHECK((LyricString*)(intptr_t)got == v1);

    CHECK(lyric_map_remove(m, (int64_t)(intptr_t)k1b));
    CHECK(atomic_load(&k1->rc) == 1);
    CHECK(atomic_load(&v1->rc) == 1);
    lyric_release(m);
    lyric_release(k1);
    lyric_release(k1b);
    lyric_release(v1);
}

static void test_posix(void) {
    CHECK(lyric_o_rdonly() == 0);
    CHECK(lyric_mutex_size() > 0);

    char mutex_buf[128];
    CHECK(lyric_mutex_size() <= (int32_t)sizeof(mutex_buf));
    lyric_mutex_init(mutex_buf);
    lyric_mutex_lock(mutex_buf);
    lyric_mutex_unlock(mutex_buf);
    lyric_mutex_destroy(mutex_buf);

    CHECK(lyric_epoch_millis() > 1000000000000LL); /* after 2001 */
    int64_t t1 = lyric_monotonic_nanos();
    int64_t t2 = lyric_monotonic_nanos();
    CHECK(t2 >= t1);

    uint8_t rnd[64] = {0};
    CHECK(lyric_secure_random(rnd, 64) == 0);
    int all_zero = 1;
    for (int i = 0; i < 64; i++) {
        if (rnd[i] != 0) all_zero = 0;
    }
    CHECK(!all_zero);

    CHECK(lyric_file_size("/nonexistent-lyric-rt-test-path") == -1);
}

static void test_file_io(void) {
    char dir_tmpl[] = "/tmp/lyric_rt_test_fs_XXXXXX";
    char* dir = mkdtemp(dir_tmpl);
    CHECK(dir != NULL);

    char path[512];
    snprintf(path, sizeof path, "%s/a.txt", dir);

    /* Whole-file write + read round trip. */
    LyricString* content = lyric_string_from_literal((const uint8_t*)"hello, file", 11);
    CHECK(lyric_file_write_all(path, content, 0) == 0);
    CHECK(lyric_file_exists(path));
    CHECK(!lyric_file_exists(dir)); /* a directory is not a "file" */

    LyricString* got = lyric_file_read_all(path);
    CHECK(got != NULL);
    CHECK(lyric_string_len(got) == 11);
    CHECK(memcmp(LYRIC_STRING_DATA(got), "hello, file", 11) == 0);
    lyric_release(got);

    /* Append mode. */
    LyricString* more = lyric_string_from_literal((const uint8_t*)"!", 1);
    CHECK(lyric_file_write_all(path, more, 1) == 0);
    LyricString* got2 = lyric_file_read_all(path);
    CHECK(lyric_string_len(got2) == 12);
    CHECK(memcmp(LYRIC_STRING_DATA(got2), "hello, file!", 12) == 0);
    lyric_release(got2);

    /* Non-append (truncate) mode overwrites. */
    LyricString* replaced = lyric_string_from_literal((const uint8_t*)"x", 1);
    CHECK(lyric_file_write_all(path, replaced, 0) == 0);
    LyricString* got3 = lyric_file_read_all(path);
    CHECK(lyric_string_len(got3) == 1);
    CHECK(LYRIC_STRING_DATA(got3)[0] == 'x');
    lyric_release(got3);

    /* fd-level open/close. */
    int32_t fd = lyric_file_open(path, lyric_o_rdonly(), 0);
    CHECK(fd >= 0);
    CHECK(lyric_file_close(fd) == 0);
    CHECK(lyric_file_close(-1) == -1);

    /* Rename. */
    char path2[512];
    snprintf(path2, sizeof path2, "%s/b.txt", dir);
    CHECK(lyric_file_rename(path, path2) == 0);
    CHECK(!lyric_file_exists(path));
    CHECK(lyric_file_exists(path2));

    /* Delete. */
    CHECK(lyric_file_delete(path2) == 0);
    CHECK(!lyric_file_exists(path2));
    CHECK(lyric_file_delete(path2) == -1); /* already gone */

    /* Missing-file reads/opens fail cleanly. */
    CHECK(lyric_file_read_all(path2) == NULL);
    CHECK(lyric_file_open(path2, lyric_o_rdonly(), 0) == -1);

    lyric_release(content);
    lyric_release(more);
    lyric_release(replaced);
    rmdir(dir);
}

static void test_directories(void) {
    char dir_tmpl[] = "/tmp/lyric_rt_test_dir_XXXXXX";
    char* dir = mkdtemp(dir_tmpl);
    CHECK(dir != NULL);

    char sub[512];
    snprintf(sub, sizeof sub, "%s/sub", dir);
    CHECK(!lyric_dir_exists(sub));
    CHECK(lyric_dir_create(sub) == 0);
    CHECK(lyric_dir_exists(sub));
    CHECK(!lyric_file_exists(sub)); /* a directory is not a "file" */
    CHECK(lyric_dir_create(sub) == -1); /* already exists */

    /* Populate `dir` with two files and the `sub` directory, then list. */
    char f1[512], f2[512];
    snprintf(f1, sizeof f1, "%s/one.txt", dir);
    snprintf(f2, sizeof f2, "%s/two.txt", dir);
    LyricString* empty = lyric_string_from_literal((const uint8_t*)"", 0);
    CHECK(lyric_file_write_all(f1, empty, 0) == 0);
    CHECK(lyric_file_write_all(f2, empty, 0) == 0);
    lyric_release(empty);

    LyricList* entries = lyric_dir_list(dir);
    CHECK(entries != NULL);
    CHECK(lyric_list_len(entries) == 3); /* one.txt, two.txt, sub — no "." / ".." */
    int saw_one = 0, saw_two = 0, saw_sub = 0, saw_dot = 0;
    for (int64_t i = 0; i < lyric_list_len(entries); i++) {
        LyricString* name = (LyricString*)(intptr_t)lyric_list_get(entries, i);
        const char* cs = lyric_string_to_cstring(name);
        if (strcmp(cs, "one.txt") == 0) saw_one = 1;
        if (strcmp(cs, "two.txt") == 0) saw_two = 1;
        if (strcmp(cs, "sub") == 0) saw_sub = 1;
        if (strcmp(cs, ".") == 0 || strcmp(cs, "..") == 0) saw_dot = 1;
        lyric_cstring_free(cs);
    }
    CHECK(saw_one && saw_two && saw_sub && !saw_dot);
    lyric_release(entries);

    CHECK(lyric_dir_list("/nonexistent-lyric-rt-test-dir") == NULL);

    /* Removal: non-empty dir fails, empty dir succeeds. */
    CHECK(lyric_dir_remove(dir) == -1); /* not empty */
    CHECK(lyric_dir_remove(sub) == 0);
    CHECK(!lyric_dir_exists(sub));

    unlink(f1);
    unlink(f2);
    CHECK(lyric_dir_remove(dir) == 0);
    CHECK(!lyric_dir_exists(dir));
}

static void test_environment(void) {
    static const char* name = "LYRIC_RT_TEST_ENV_VAR_UNIQUE";
    CHECK(lyric_env_get(name) == NULL);

    CHECK(lyric_env_set(name, "first") == 0);
    LyricString* v1 = lyric_env_get(name);
    CHECK(v1 != NULL);
    CHECK(lyric_string_len(v1) == 5);
    CHECK(memcmp(LYRIC_STRING_DATA(v1), "first", 5) == 0);
    lyric_release(v1);

    /* setenv always overwrites. */
    CHECK(lyric_env_set(name, "second") == 0);
    LyricString* v2 = lyric_env_get(name);
    CHECK(lyric_string_len(v2) == 6);
    CHECK(memcmp(LYRIC_STRING_DATA(v2), "second", 6) == 0);
    lyric_release(v2);

    LyricString* cwd = lyric_env_cwd();
    CHECK(cwd != NULL);
    CHECK(lyric_string_len(cwd) > 0);
    CHECK(LYRIC_STRING_DATA(cwd)[0] == '/'); /* absolute path */
    lyric_release(cwd);

    unsetenv(name);
}

static void test_process(void) {
    /* /bin/echo hello world -> stdout "hello world\n", exit 0, empty stderr. */
    LyricList* args = lyric_list_new(1);
    LyricString* a1 = lyric_string_from_literal((const uint8_t*)"hello", 5);
    LyricString* a2 = lyric_string_from_literal((const uint8_t*)"world", 5);
    lyric_list_push(args, (int64_t)(intptr_t)a1);
    lyric_list_push(args, (int64_t)(intptr_t)a2);
    lyric_release(a1);
    lyric_release(a2);

    int32_t exit_code = -99;
    LyricString* out = NULL;
    LyricString* err = NULL;
    CHECK(lyric_process_run("/bin/echo", args, &exit_code, &out, &err) == 0);
    CHECK(exit_code == 0);
    CHECK(out != NULL);
    CHECK(lyric_string_len(out) == 12);
    CHECK(memcmp(LYRIC_STRING_DATA(out), "hello world\n", 12) == 0);
    CHECK(err != NULL);
    CHECK(lyric_string_len(err) == 0);
    lyric_release(out);
    lyric_release(err);
    lyric_release(args);

    /* /bin/ls of a nonexistent path -> nonzero exit, non-empty stderr. */
    LyricList* bad_args = lyric_list_new(1);
    LyricString* bad_path =
        lyric_string_from_literal((const uint8_t*)"/nonexistent-lyric-rt-test-path", 32);
    lyric_list_push(bad_args, (int64_t)(intptr_t)bad_path);
    lyric_release(bad_path);

    int32_t exit_code2 = -99;
    LyricString* out2 = NULL;
    LyricString* err2 = NULL;
    CHECK(lyric_process_run("/bin/ls", bad_args, &exit_code2, &out2, &err2) == 0);
    CHECK(exit_code2 != 0);
    CHECK(lyric_string_len(err2) > 0);
    lyric_release(out2);
    lyric_release(err2);
    lyric_release(bad_args);

    /* No args: argv is just argv[0]. */
    int32_t exit_code3 = -99;
    LyricString* out3 = NULL;
    LyricString* err3 = NULL;
    CHECK(lyric_process_run("/bin/echo", NULL, &exit_code3, &out3, &err3) == 0);
    CHECK(exit_code3 == 0);
    CHECK(lyric_string_len(out3) == 1); /* just the trailing newline */
    lyric_release(out3);
    lyric_release(err3);

    /* Spawn failure (path lookup handled by execvp inside the child, so
     * a missing executable is exit code 127, not a spawn failure): */
    int32_t exit_code4 = -99;
    LyricString* out4 = NULL;
    LyricString* err4 = NULL;
    CHECK(lyric_process_run("/nonexistent-lyric-rt-test-exe", NULL, &exit_code4, &out4, &err4) ==
          0);
    CHECK(exit_code4 == 127);
    lyric_release(out4);
    lyric_release(err4);
}

int main(void) {
    test_alloc_retain_release();
    test_strings();
    test_weak();
    test_list_scalars();
    test_list_refs();
    test_map_int_keys();
    test_map_string_keys();
    test_posix();
    test_file_io();
    test_directories();
    test_environment();
    test_process();
    if (failures == 0) {
        printf("lyric_rt_test: all tests passed\n");
        return 0;
    }
    fprintf(stderr, "lyric_rt_test: %d failure(s)\n", failures);
    return 1;
}
