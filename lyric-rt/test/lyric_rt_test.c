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
#include <signal.h>
#include <time.h>
#include <sys/wait.h>
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
    void* raw16 = lyric_alloc(16);
    CHECK(raw16 != NULL);
    lyric_free(raw16);

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

/* lyric_free frees a raw (non-ARC-header) buffer, e.g. a protected type's
 * runtime-sized mutex buffer (D-N-017).  A double free or a leak here trips
 * AddressSanitizer when the suite is built with -fsanitize=address. */
static void test_free(void) {
    /* NULL is a no-op. */
    lyric_free(NULL);

    /* alloc + free a raw buffer sized like a pthread_mutex_t. */
    void* p = lyric_alloc((uint64_t)lyric_mutex_size());
    CHECK(p != NULL);
    lyric_free(p);

    /* A second, differently-sized buffer to catch size-mismatch bookkeeping. */
    void* q = lyric_alloc(1);
    CHECK(q != NULL);
    lyric_free(q);
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

static void test_list_copy(void) {
    /* Ref elements: the copy retains; releasing the source leaves the
     * copy's elements alive. */
    LyricList* src = lyric_list_new(1);
    LyricString* a = lyric_string_from_literal((const uint8_t*)"one", 3);
    lyric_list_push(src, (int64_t)(intptr_t)a);
    lyric_release(a);
    LyricList* dup = lyric_list_copy(src);
    CHECK(lyric_list_len(dup) == 1);
    CHECK(atomic_load(&a->rc) == 2); /* held by src and dup */
    lyric_release(src);
    CHECK(atomic_load(&a->rc) == 1);
    LyricString* got = (LyricString*)(intptr_t)lyric_list_get(dup, 0);
    CHECK(memcmp(LYRIC_STRING_DATA(got), "one", 3) == 0);
    lyric_release(dup);

    /* Scalar elements copy bit-for-bit. */
    LyricList* nums = lyric_list_new(0);
    lyric_list_push(nums, 7);
    lyric_list_push(nums, 42);
    LyricList* nums2 = lyric_list_copy(nums);
    lyric_list_set(nums, 0, -1);
    CHECK(lyric_list_get(nums2, 0) == 7);
    CHECK(lyric_list_get(nums2, 1) == 42);
    lyric_release(nums);
    lyric_release(nums2);

    /* NULL src degrades to a fresh empty list, not a crash (#4851). */
    LyricList* empty = lyric_list_copy(NULL);
    CHECK(empty != NULL);
    CHECK(lyric_list_len(empty) == 0);
    lyric_release(empty);
}

static void test_read_bytes(void) {
    char tmpl[] = "/tmp/lyric_rt_bytes_XXXXXX";
    int fd = mkstemp(tmpl);
    CHECK(fd >= 0);
    CHECK(write(fd, "hi\x00z", 4) == 4);
    close(fd);
    int32_t ok = 0;
    LyricList* bytes = lyric_file_read_bytes(tmpl, &ok);
    CHECK(ok == 1);
    CHECK(lyric_list_len(bytes) == 4);
    CHECK(lyric_list_get(bytes, 0) == 'h');
    CHECK(lyric_list_get(bytes, 1) == 'i');
    CHECK(lyric_list_get(bytes, 2) == 0); /* interior NUL survives */
    CHECK(lyric_list_get(bytes, 3) == 'z');
    lyric_release(bytes);
    unlink(tmpl);
    int32_t ok2 = 1;
    LyricList* missing = lyric_file_read_bytes("/definitely/missing/lyric-rt", &ok2);
    CHECK(ok2 == 0);
    CHECK(lyric_list_len(missing) == 0);
    lyric_release(missing);
}

static void test_write_bytes(void) {
    char tmpl[] = "/tmp/lyric_rt_wbytes_XXXXXX";
    int fd = mkstemp(tmpl);
    CHECK(fd >= 0);
    close(fd);

    /* Truncate-write, interior NUL survives the round-trip. */
    LyricList* data = lyric_list_new(0);
    lyric_list_push(data, 'h');
    lyric_list_push(data, 0);
    lyric_list_push(data, 'z');
    CHECK(lyric_file_write_bytes(tmpl, data, 0) == 0);
    lyric_release(data);
    int32_t ok = 0;
    LyricList* back = lyric_file_read_bytes(tmpl, &ok);
    CHECK(ok == 1);
    CHECK(lyric_list_len(back) == 3);
    CHECK(lyric_list_get(back, 0) == 'h');
    CHECK(lyric_list_get(back, 1) == 0);
    CHECK(lyric_list_get(back, 2) == 'z');
    lyric_release(back);

    /* Append flag extends rather than truncates. */
    LyricList* extra = lyric_list_new(0);
    lyric_list_push(extra, '!');
    CHECK(lyric_file_write_bytes(tmpl, extra, 1) == 0);
    lyric_release(extra);
    LyricList* back2 = lyric_file_read_bytes(tmpl, &ok);
    CHECK(ok == 1);
    CHECK(lyric_list_len(back2) == 4);
    CHECK(lyric_list_get(back2, 3) == '!');
    lyric_release(back2);

    /* Empty-list truncate-write leaves an empty file. */
    LyricList* none = lyric_list_new(0);
    CHECK(lyric_file_write_bytes(tmpl, none, 0) == 0);
    lyric_release(none);
    LyricList* back3 = lyric_file_read_bytes(tmpl, &ok);
    CHECK(ok == 1);
    CHECK(lyric_list_len(back3) == 0);
    lyric_release(back3);
    unlink(tmpl);

    /* Unwritable path reports failure. */
    LyricList* d2 = lyric_list_new(0);
    lyric_list_push(d2, 'x');
    CHECK(lyric_file_write_bytes("/definitely/missing/lyric-rt-w", d2, 0) == -1);
    lyric_release(d2);
}

static void test_dir_list2(void) {
    /* Missing directory: the ok-flag protocol must report failure with a
     * fresh empty list, never ok=1 (the native listFiles/listDirs seams
     * classify IO failures solely from this flag). */
    int32_t ok = 1;
    LyricList* missing = lyric_dir_list2("/definitely/missing/lyric-rt-dir", &ok);
    CHECK(ok == 0);
    CHECK(lyric_list_len(missing) == 0);
    lyric_release(missing);

    char tmpl[] = "/tmp/lyric_rt_dir2_XXXXXX";
    CHECK(mkdtemp(tmpl) != NULL);

    /* Existing but EMPTY directory: ok=1 with zero entries — existence
     * and content are reported independently. */
    int32_t ok0 = 0;
    LyricList* none = lyric_dir_list2(tmpl, &ok0);
    CHECK(ok0 == 1);
    CHECK(lyric_list_len(none) == 0);
    lyric_release(none);

    /* Existing directory with content: ok=1 and the entry appears by name. */
    char inner[512];
    snprintf(inner, sizeof inner, "%s/entry.txt", tmpl);
    FILE* f = fopen(inner, "w");
    CHECK(f != NULL);
    fclose(f);
    int32_t ok2 = 0;
    LyricList* names = lyric_dir_list2(tmpl, &ok2);
    CHECK(ok2 == 1);
    CHECK(lyric_list_len(names) == 1);
    LyricString* n0 = (LyricString*)(intptr_t)lyric_list_get(names, 0);
    CHECK(lyric_string_len(n0) == 9);
    CHECK(memcmp(LYRIC_STRING_DATA(n0), "entry.txt", 9) == 0);
    lyric_release(names);
    unlink(inner);
    rmdir(tmpl);
}

static void test_is_dir_nofollow(void) {
    /* A real directory is a directory; a file is not. */
    char tmpl[] = "/tmp/lyric_rt_nofollow_XXXXXX";
    CHECK(mkdtemp(tmpl) != NULL);
    CHECK(lyric_path_is_dir_nofollow(tmpl) == 1);

    char filep[512];
    snprintf(filep, sizeof filep, "%s/f.txt", tmpl);
    FILE* f = fopen(filep, "w");
    CHECK(f != NULL);
    fclose(f);
    CHECK(lyric_path_is_dir_nofollow(filep) == 0);

    /* A symlink pointing AT the directory is NOT a directory here (the
     * whole point: recursive delete must unlink it, not descend). */
    char linkp[512];
    snprintf(linkp, sizeof linkp, "%s/link", tmpl);
    CHECK(symlink(tmpl, linkp) == 0);
    CHECK(lyric_path_is_dir_nofollow(linkp) == 0);
    /* lyric_dir_exists (stat, follows) DOES see it as a directory — the
     * exact divergence that made the naive delete unsafe. */
    CHECK(lyric_dir_exists(linkp) == 1);

    /* Missing path: 0, no crash. */
    CHECK(lyric_path_is_dir_nofollow("/definitely/missing/lyric-rt-nf") == 0);

    unlink(linkp);
    unlink(filep);
    rmdir(tmpl);
}

static void test_args(void) {
    /* Unset: empty list rather than a crash. */
    LyricList* empty = lyric_args_get();
    CHECK(lyric_list_len(empty) == 0);
    lyric_release(empty);

    char* argv[] = {(char*)"prog", (char*)"alpha", (char*)"beta"};
    lyric_args_set(3, argv);
    LyricList* got = lyric_args_get();
    CHECK(lyric_list_len(got) == 3);
    LyricString* s1 = (LyricString*)(intptr_t)lyric_list_get(got, 1);
    CHECK(memcmp(LYRIC_STRING_DATA(s1), "alpha", 5) == 0);
    lyric_release(got);
    lyric_args_set(0, NULL);
}

static void test_map_keys_values(void) {
    /* Scalar keys, ref values: keys list is scalar, values list retains. */
    LyricMap* m = lyric_map_new(0, 1);
    LyricString* v1 = lyric_string_from_literal((const uint8_t*)"one", 3);
    LyricString* v2 = lyric_string_from_literal((const uint8_t*)"two", 3);
    lyric_map_set(m, 1, (int64_t)(intptr_t)v1);
    lyric_map_set(m, 2, (int64_t)(intptr_t)v2);
    lyric_release(v1);
    lyric_release(v2);

    LyricList* ks = lyric_map_keys(m);
    LyricList* vs = lyric_map_values(m);
    CHECK(lyric_list_len(ks) == 2);
    CHECK(lyric_list_len(vs) == 2);
    int64_t ksum = lyric_list_get(ks, 0) + lyric_list_get(ks, 1);
    CHECK(ksum == 3);
    /* Values list retained its entries: releasing the map first must
     * leave the strings alive through the list. */
    lyric_release(m);
    LyricString* got = (LyricString*)(intptr_t)lyric_list_get(vs, 0);
    CHECK(lyric_string_len(got) == 3);
    lyric_release(ks);
    lyric_release(vs);
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

    LyricString* cwd2 = NULL;
    CHECK(lyric_env_cwd_ok(&cwd2) == 0);
    CHECK(cwd2 != NULL);
    CHECK(lyric_string_len(cwd2) > 0);
    lyric_release(cwd2);

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

static void test_process_closed_stdio(void) {
    /* Regression: with fd 1/2 closed in the caller, pipe() hands the child
     * those very numbers, dup2 onto itself is a no-op, and the old
     * unconditional close then destroyed the just-installed descriptor.
     * Run a capture with stdout/stderr closed and verify the output still
     * comes back intact.  Assertions in the fork are reported through the
     * exit status — its stderr is closed by construction. */
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
        /* With 1/2 closed, pipe() returns {1,2} for out_pipe, so the old
         * close(out_pipe[1]) destroyed the descriptor stderr had just been
         * dup2'ed onto.  The command must write to BOTH streams: with the
         * bug, its stderr writes hit a closed fd and the err capture comes
         * back empty. */
        LyricList* args = lyric_list_new(2);
        LyricString* a1 = lyric_string_from_literal((const uint8_t*)"-c", 2);
        LyricString* a2 = lyric_string_from_literal(
            (const uint8_t*)"echo out; echo err 1>&2", 23);
        lyric_list_push(args, (int64_t)(intptr_t)a1);
        lyric_list_push(args, (int64_t)(intptr_t)a2);
        lyric_release(a1);
        lyric_release(a2);
        int32_t code = -99;
        LyricString* out = NULL;
        LyricString* err = NULL;
        if (lyric_process_run("/bin/sh", args, &code, &out, &err) != 0) _exit(1);
        if (code != 0) _exit(2);
        if (!out || lyric_string_len(out) != 4) _exit(3);
        if (memcmp(LYRIC_STRING_DATA(out), "out\n", 4) != 0) _exit(4);
        if (!err || lyric_string_len(err) != 4) _exit(5);
        if (memcmp(LYRIC_STRING_DATA(err), "err\n", 4) != 0) _exit(6);
        _exit(0);
    }
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFEXITED(status));
    CHECK(WEXITSTATUS(status) == 0);
}

static void test_process_closed_stdin_stdout(void) {
    /* With fds 0 and 1 closed, pipe() returns {0,1} for out_pipe, so
     * out_pipe[1] IS STDOUT_FILENO and the child takes the no-dup2 branch.
     * The pipes are created CLOEXEC; the child must clear the flag by hand
     * on that branch or exec closes the just-wired stdout and the capture
     * comes back empty. */
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        LyricList* args = lyric_list_new(1);
        LyricString* a = lyric_string_from_literal((const uint8_t*)"hi", 2);
        lyric_list_push(args, (int64_t)(intptr_t)a);
        lyric_release(a);
        int32_t code = -99;
        LyricString* out = NULL;
        LyricString* err = NULL;
        if (lyric_process_run("/bin/echo", args, &code, &out, &err) != 0) _exit(1);
        if (code != 0) _exit(2);
        if (!out || lyric_string_len(out) != 3) _exit(3);
        if (memcmp(LYRIC_STRING_DATA(out), "hi\n", 3) != 0) _exit(4);
        _exit(0);
    }
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFEXITED(status));
    CHECK(WEXITSTATUS(status) == 0);
}

/* ── Nonblocking process op (the async process leaf, D-N-023) ───────── */
static void test_process_op_basic(void) {
    /* echo through the pump loop: start, pump until done, read results. */
    LyricList* args = lyric_list_new(1);
    LyricString* a = lyric_string_from_literal((const uint8_t*)"pump", 4);
    lyric_list_push(args, (int64_t)(intptr_t)a);
    lyric_release(a);
    void* op = lyric_process_start("/bin/echo", args);
    lyric_release(args);
    CHECK(!lyric_process_spawn_failed(op));
    int spins = 0;
    while (!lyric_process_pump(op) && spins < 5000) {
        struct timespec ts = {0, 1000000}; /* 1 ms — the kernel's poll cadence */
        nanosleep(&ts, NULL);
        spins++;
    }
    CHECK(lyric_process_pump(op) == 1);
    CHECK(lyric_process_exit_code(op) == 0);
    LyricString* out = lyric_process_stdout(op);
    LyricString* errs = lyric_process_stderr(op);
    CHECK(lyric_string_len(out) == 5);
    CHECK(memcmp(LYRIC_STRING_DATA(out), "pump\n", 5) == 0);
    CHECK(lyric_string_len(errs) == 0);
    lyric_release(out);
    lyric_release(errs);
    lyric_process_free(op);
}

static void test_process_op_kill(void) {
    /* A sleeping child killed mid-run: partial output preserved, op done,
     * signal-termination exit code reported. */
    LyricList* argv = lyric_list_new(1);
    LyricString* dash_c = lyric_string_from_literal((const uint8_t*)"-c", 2);
    lyric_list_push(argv, (int64_t)(intptr_t)dash_c);
    lyric_release(dash_c);
    LyricString* script = lyric_string_from_literal((const uint8_t*)"echo pre; sleep 30", 18);
    lyric_list_push(argv, (int64_t)(intptr_t)script);
    lyric_release(script);
    void* op = lyric_process_start("/bin/sh", argv);
    lyric_release(argv);
    CHECK(!lyric_process_spawn_failed(op));
    /* Give the child time to print "pre" (pump meanwhile). */
    int spins = 0;
    LyricString* probe = NULL;
    for (;;) {
        lyric_process_pump(op);
        probe = lyric_process_stdout(op);
        int64_t got = lyric_string_len(probe);
        lyric_release(probe);
        if (got >= 4 || spins >= 5000) break;
        struct timespec ts = {0, 1000000};
        nanosleep(&ts, NULL);
        spins++;
    }
    CHECK(!lyric_process_pump(op)); /* still sleeping — not done */
    CHECK(lyric_process_kill(op) == 1); /* the kill terminated it */
    CHECK(lyric_process_pump(op) == 1);
    CHECK(lyric_process_exit_code(op) == 128 + SIGKILL);
    LyricString* out = lyric_process_stdout(op);
    CHECK(lyric_string_len(out) == 4);
    CHECK(memcmp(LYRIC_STRING_DATA(out), "pre\n", 4) == 0);
    lyric_release(out);
    lyric_process_free(op);
}

static void test_process_op_kill_after_exit(void) {
    /* kill on an op whose child already finished must NOT report a
     * kill (#5107: the deadline can fire inside the window between the
     * child exiting and the WNOHANG reap seeing it — a false timeout).
     * A done op returns 0; the real exit status stays intact. */
    LyricList* args = lyric_list_new(1);
    LyricString* a = lyric_string_from_literal((const uint8_t*)"beat-the-kill", 13);
    lyric_list_push(args, (int64_t)(intptr_t)a);
    lyric_release(a);
    void* op = lyric_process_start("/bin/echo", args);
    lyric_release(args);
    int spins = 0;
    while (!lyric_process_pump(op) && spins < 5000) {
        struct timespec ts = {0, 1000000};
        nanosleep(&ts, NULL);
        spins++;
    }
    CHECK(lyric_process_pump(op) == 1);
    CHECK(lyric_process_kill(op) == 0); /* already exited — not a kill */
    CHECK(lyric_process_exit_code(op) == 0); /* real status preserved */
    lyric_process_free(op);
}

static void test_process_op_exec_failure(void) {
    /* execvp failure inside the child: exit 127, empty output, no spawn
     * failure (matching lyric_process_run and shell convention). */
    void* op = lyric_process_start("/nonexistent-lyric-op-binary", NULL);
    CHECK(!lyric_process_spawn_failed(op));
    int spins = 0;
    while (!lyric_process_pump(op) && spins < 5000) {
        struct timespec ts = {0, 1000000};
        nanosleep(&ts, NULL);
        spins++;
    }
    CHECK(lyric_process_pump(op) == 1);
    CHECK(lyric_process_exit_code(op) == 127);
    LyricString* out = lyric_process_stdout(op);
    CHECK(lyric_string_len(out) == 0);
    lyric_release(out);
    lyric_process_free(op);
}

static void test_ok_variants(void) {
    char tmpl[] = "/tmp/lyric_rt_ok_XXXXXX";
    int fd = mkstemp(tmpl);
    CHECK(fd >= 0);
    CHECK(write(fd, "hi", 2) == 2);
    close(fd);
    LyricString* content = NULL;
    CHECK(lyric_file_read_all_ok(tmpl, &content) == 0);
    CHECK(content && lyric_string_len(content) == 2);
    lyric_release(content);
    LyricString* missing = NULL;
    CHECK(lyric_file_read_all_ok("/nonexistent-lyric-ok-path", &missing) == -1);
    CHECK(missing == NULL);
    unlink(tmpl);

    CHECK(lyric_env_set("LYRIC_RT_OK_TEST", "v") == 0);
    LyricString* v = NULL;
    CHECK(lyric_env_get_ok("LYRIC_RT_OK_TEST", &v) == 0);
    CHECK(v && lyric_string_len(v) == 1);
    lyric_release(v);
    LyricString* nov = NULL;
    CHECK(lyric_env_get_ok("LYRIC_RT_OK_TEST_MISSING", &nov) == -1);
    CHECK(nov == NULL);
    unsetenv("LYRIC_RT_OK_TEST");
}

/* ── Async scheduler (lyric_async.c) ─────────────────────────────────
 *
 * The real system resumes LLVM coroutine frames through the generated
 * `lyric_coro_resume`/`lyric_coro_destroy` wrappers; here those symbols
 * are defined over FakeCoro handles instead — a step-indexed C state
 * machine that plays the exact protocol the codegen will emit: register
 * (await/sleep) then return to simulate a suspend, `lyric_task_complete`
 * then return to simulate the final suspend.
 */
typedef struct FakeCoro {
    LyricTask* task;
    int step;
    int destroyed;
    void (*body)(struct FakeCoro*);
    struct FakeCoro* dep; /* another fake coro this one awaits, if any */
    int64_t sleep1_ms;
    int64_t sleep2_ms;
    char tag1;
    char tag2;
} FakeCoro;

void lyric_coro_resume(void* hdl) {
    FakeCoro* c = (FakeCoro*)hdl;
    c->body(c);
}

void lyric_coro_destroy(void* hdl) {
    ((FakeCoro*)hdl)->destroyed = 1;
}

/* The hot ramp: create the task, run the body inline until it first
 * "suspends" (returns), hand the caller its rc=1 task — exactly the
 * calling convention stage B's codegen emits for an async call. */
static LyricTask* fake_call(FakeCoro* c) {
    c->task = lyric_task_new(c);
    LyricTask* prev = lyric_current_task();
    lyric_set_current_task(c->task);
    c->body(c);
    lyric_set_current_task(prev);
    return c->task;
}

static char async_log[32];
static int async_log_len = 0;

static void async_log_push(char tag) {
    if (async_log_len < (int)sizeof(async_log) - 1) {
        async_log[async_log_len++] = tag;
        async_log[async_log_len] = 0;
    }
}

/* Body: complete immediately with 42 (never suspends — pure hot path). */
static void body_immediate(FakeCoro* c) {
    lyric_task_complete(c->task, 42, 0);
    c->step = -1;
}

/* Body: sleep tag1 ms, log tag1, sleep tag2 ms, log tag2, complete. */
static void body_two_sleeps(FakeCoro* c) {
    if (c->step == 0) {
        c->step = 1;
        lyric_async_sleep(c->task, c->sleep1_ms);
        return;
    }
    if (c->step == 1) {
        async_log_push(c->tag1);
        c->step = 2;
        lyric_async_sleep(c->task, c->sleep2_ms);
        return;
    }
    async_log_push(c->tag2);
    lyric_task_complete(c->task, (int64_t)c->tag2, 0);
    c->step = -1;
}

/* Body: await dep (registering only if incomplete), then complete with
 * dep's result + 1, logging tag1 (when set) at completion so tests can
 * assert wake ORDER, not just wake-at-all. */
static void body_await_dep(FakeCoro* c) {
    if (c->step == 0 && !lyric_task_is_complete(c->dep->task)) {
        c->step = 1;
        lyric_async_await(c->task, c->dep->task);
        return;
    }
    if (c->tag1) {
        async_log_push(c->tag1);
    }
    lyric_task_complete(c->task, lyric_task_result(c->dep->task) + 1, 0);
    c->step = -1;
}

/* Body: sleep once, then complete with 7. */
static void body_sleep_once(FakeCoro* c) {
    if (c->step == 0) {
        c->step = 1;
        lyric_async_sleep(c->task, c->sleep1_ms);
        return;
    }
    lyric_task_complete(c->task, 7, 0);
    c->step = -1;
}

static void test_async_hot_completion(void) {
    /* A never-suspending task completes inside the ramp: no scheduling,
     * result readable immediately, frame destroyed when the last ref
     * drops. */
    FakeCoro c = {0};
    c.body = body_immediate;
    LyricTask* t = fake_call(&c);
    CHECK(lyric_task_is_complete(t));
    CHECK(lyric_task_result(t) == 42);
    CHECK(!c.destroyed);
    lyric_release(t);
    CHECK(c.destroyed);
}

static void test_async_block_on_sleep(void) {
    /* One sleeping task driven to completion by block_on. */
    FakeCoro c = {0};
    c.body = body_sleep_once;
    c.sleep1_ms = 5;
    LyricTask* t = fake_call(&c);
    CHECK(!lyric_task_is_complete(t));
    lyric_task_block_on(t);
    CHECK(lyric_task_is_complete(t));
    CHECK(lyric_task_result(t) == 7);
    lyric_release(t);
    CHECK(c.destroyed);
}

static void test_async_interleave(void) {
    /* Two tasks with interleaved timer deadlines make progress in
     * deadline order, not spawn order: a@20, b@40, A@~80, B@~130.
     * Deadlines are computed from the ACTUAL wake time (now + ms), so
     * near-ties would be decided by scheduling jitter — every gap here
     * is >= 20 ms of ideal separation (20/40/50 ms), which only a
     * differential stall of the gap size between two adjacent resumes
     * could reorder. */
    async_log_len = 0;
    async_log[0] = 0;
    FakeCoro a = {0};
    a.body = body_two_sleeps;
    a.sleep1_ms = 20;
    a.sleep2_ms = 60; /* wakes at ~20, then ~80 */
    a.tag1 = 'a';
    a.tag2 = 'A';
    FakeCoro b = {0};
    b.body = body_two_sleeps;
    b.sleep1_ms = 40;
    b.sleep2_ms = 90; /* wakes at ~40, then ~130 */
    b.tag1 = 'b';
    b.tag2 = 'B';
    LyricTask* ta = fake_call(&a);
    LyricTask* tb = fake_call(&b);
    CHECK(!lyric_task_is_complete(ta));
    CHECK(!lyric_task_is_complete(tb));
    lyric_task_block_on(ta);
    lyric_task_block_on(tb);
    CHECK(strcmp(async_log, "abAB") == 0);
    lyric_release(ta);
    lyric_release(tb);
    CHECK(a.destroyed);
    CHECK(b.destroyed);
}

static void test_async_await_chain(void) {
    /* root awaits mid awaits leaf: completion propagates leaf -> mid ->
     * root through the waiter lists. */
    FakeCoro leaf = {0};
    leaf.body = body_sleep_once;
    leaf.sleep1_ms = 3;
    FakeCoro mid = {0};
    mid.body = body_await_dep;
    mid.dep = &leaf;
    FakeCoro root = {0};
    root.body = body_await_dep;
    root.dep = &mid;
    LyricTask* tleaf = fake_call(&leaf);
    LyricTask* tmid = fake_call(&mid);
    LyricTask* troot = fake_call(&root);
    CHECK(!lyric_task_is_complete(troot));
    lyric_task_block_on(troot);
    CHECK(lyric_task_result(tleaf) == 7);
    CHECK(lyric_task_result(tmid) == 8);
    CHECK(lyric_task_result(troot) == 9);
    lyric_release(tleaf);
    lyric_release(tmid);
    lyric_release(troot);
    CHECK(leaf.destroyed && mid.destroyed && root.destroyed);
}

static void test_async_multi_waiters(void) {
    /* Two tasks parked on the same dependency both wake when it
     * completes — in REGISTRATION order (FIFO fairness, #5082: a LIFO
     * waiter list would resume w2 before w1). */
    async_log_len = 0;
    async_log[0] = 0;
    FakeCoro leaf = {0};
    leaf.body = body_sleep_once;
    leaf.sleep1_ms = 3;
    FakeCoro w1 = {0};
    w1.body = body_await_dep;
    w1.dep = &leaf;
    w1.tag1 = '1';
    FakeCoro w2 = {0};
    w2.body = body_await_dep;
    w2.dep = &leaf;
    w2.tag1 = '2';
    LyricTask* tleaf = fake_call(&leaf);
    LyricTask* t1 = fake_call(&w1);
    LyricTask* t2 = fake_call(&w2);
    lyric_task_block_on(t1);
    lyric_task_block_on(t2);
    CHECK(lyric_task_result(t1) == 8);
    CHECK(lyric_task_result(t2) == 8);
    CHECK(strcmp(async_log, "12") == 0);
    lyric_release(tleaf);
    lyric_release(t1);
    lyric_release(t2);
    CHECK(leaf.destroyed && w1.destroyed && w2.destroyed);
}

static void test_async_sleep_saturates(void) {
    /* An absurdly large sleep must saturate the nanosecond deadline
     * (#5083) — without the cap, `ms * 1000000` wraps negative and the
     * sleeper wakes immediately.  Forked so the never-expiring sleeper
     * leaves no residue in the parent's scheduler state. */
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        FakeCoro c = {0};
        c.body = body_sleep_once;
        c.sleep1_ms = INT64_MAX;
        LyricTask* t = fake_call(&c);
        _exit(t->wake_deadline_ns == INT64_MAX && !lyric_task_is_complete(t) ? 0 : 1);
    }
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

/* Body: await a task that can never complete (its "coroutine" was
 * never driven past RUNNING) — the deadlock detector must abort. */
static void test_async_deadlock_aborts(void) {
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        /* Silence the panic diagnostic so test output stays clean. */
        if (!freopen("/dev/null", "w", stderr)) _exit(9);
        FakeCoro stuck = {0};
        stuck.body = body_immediate; /* never actually driven */
        stuck.task = lyric_task_new(&stuck);
        FakeCoro w = {0};
        w.body = body_await_dep;
        w.dep = &stuck;
        LyricTask* tw = fake_call(&w);
        lyric_task_block_on(tw); /* no ready tasks, no timers -> panic */
        _exit(0);                /* not reached */
    }
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}

int main(void) {
    test_alloc_retain_release();
    test_free();
    test_strings();
    test_weak();
    test_list_scalars();
    test_list_refs();
    test_map_int_keys();
    test_map_string_keys();
    test_list_copy();
    test_read_bytes();
    test_write_bytes();
    test_dir_list2();
    test_is_dir_nofollow();
    test_args();
    test_map_keys_values();
    test_posix();
    test_ok_variants();
    test_file_io();
    test_directories();
    test_environment();
    test_process();
    test_process_closed_stdio();
    test_process_closed_stdin_stdout();
    test_process_op_basic();
    test_process_op_kill();
    test_process_op_kill_after_exit();
    test_process_op_exec_failure();
    test_async_hot_completion();
    test_async_block_on_sleep();
    test_async_interleave();
    test_async_await_chain();
    test_async_multi_waiters();
    test_async_sleep_saturates();
    test_async_deadlock_aborts();
    if (failures == 0) {
        printf("lyric_rt_test: all tests passed\n");
        return 0;
    }
    fprintf(stderr, "lyric_rt_test: %d failure(s)\n", failures);
    return 1;
}
