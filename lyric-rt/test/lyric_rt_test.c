/* lyric_rt_test.c — unit tests for the lyric-rt runtime (N0.4).
 * Run via `make -C lyric-rt test`.  Exits non-zero on the first failure.
 */
#include "lyric_rt.h"

#include <limits.h>
#include <stdint.h>
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

int main(void) {
    test_alloc_retain_release();
    test_strings();
    test_weak();
    test_list_scalars();
    test_list_refs();
    test_map_int_keys();
    test_map_string_keys();
    test_posix();
    if (failures == 0) {
        printf("lyric_rt_test: all tests passed\n");
        return 0;
    }
    fprintf(stderr, "lyric_rt_test: %d failure(s)\n", failures);
    return 1;
}
