/* lyric_rt_test.c — unit tests for the lyric-rt runtime (N0.4).
 * Run via `make -C lyric-rt test`.  Exits non-zero on the first failure.
 */
#if defined(__linux__) || defined(__wasi__)
/* mkstemp/mkdtemp need POSIX.1-2008 / XSI visibility under -std=c11. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef __wasi__
#include <signal.h>
#endif
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#ifndef __wasi__
#include <sys/wait.h>
#endif
#include <unistd.h>
#ifndef __wasi__
#include <pthread.h>
#endif

/* True when `s` holds exactly the bytes of the C string `want`. */
static int string_is(LyricString* s, const char* want) {
    size_t n = strlen(want);
    return lyric_string_len(s) == (int64_t)n && memcmp(LYRIC_STRING_DATA(s), want, n) == 0;
}

static int failures = 0;

#if defined(__wasi__)
/* wasi-libc has no mkstemp/mkdtemp, and the only writable location is a
 * preopened directory (`wasmtime run --dir=.`), so a "/tmp/..._XXXXXX"
 * template becomes a counter-suffixed name under the current directory. */
static void wasi_temp_name(char* tmpl) {
    static int counter = 0;
    size_t n = strlen(tmpl);
    char* x = tmpl + n - 6;
    char suffix[8];
    snprintf(suffix, sizeof suffix, "%06d", ++counter);
    memcpy(x, suffix, 6);
    const char* base = strrchr(tmpl, '/');
    memmove(tmpl, base ? base + 1 : tmpl, strlen(base ? base + 1 : tmpl) + 1);
}

static char* mkdtemp(char* tmpl) {
    wasi_temp_name(tmpl);
    return mkdir(tmpl, 0700) == 0 ? tmpl : NULL;
}

static int mkstemp(char* tmpl) {
    wasi_temp_name(tmpl);
    return open(tmpl, O_RDWR | O_CREAT | O_EXCL, 0600);
}
#endif

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
    lyric_weak_init(h);   /* birth sites must seed the implicit weak count */
    h->dtor = counting_dtor;
    dtor_calls = 0;
    lyric_retain(h);
    lyric_release(h);
    CHECK(dtor_calls == 0);
    lyric_release(h);     /* rc -> 0: dtor runs, weak -> 0, allocation freed */
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

    /* lyric_ptr_to_long / lyric_long_to_ptr: a pure bit-identical
     * round-trip, no dereference — the conversion a retained closure's
     * environment pointer needs to survive as a `Long` field
     * (_kernel_native/http_server.l's #6797 fix). */
    void* rawp = lyric_alloc(8);
    int64_t asLong = lyric_ptr_to_long(rawp);
    CHECK(lyric_long_to_ptr(asLong) == rawp);
    CHECK(lyric_ptr_to_long(NULL) == 0);
    CHECK(lyric_long_to_ptr(0) == NULL);
    lyric_free(rawp);
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

/* lyric_rt_allocated_bytes counts every byte requested through lyric_alloc
 * on this thread, and nothing else. */
static void test_allocated_bytes(void) {
    int64_t before = lyric_rt_allocated_bytes();
    void* p = lyric_alloc(48);
    CHECK(lyric_rt_allocated_bytes() - before == 48);
    lyric_free(p);
    CHECK(lyric_rt_allocated_bytes() - before == 48);
    void* q = lyric_alloc(16);
    CHECK(lyric_rt_allocated_bytes() - before == 64);
    lyric_free(q);
}

static void test_strings(void) {
    LyricString* a = lyric_string_from_literal((const uint8_t*)"hello", 5);
    LyricString* b = lyric_string_from_literal((const uint8_t*)", world", 7);
    CHECK(lyric_string_len(a) == 5);
    CHECK(lyric_string_byte_at(a, 0) == 'h');
    CHECK(lyric_string_byte_at(a, 4) == 'o');

    /* `s[i]` (#6237): byte-offset indexing that decodes the full Unicode
     * scalar value via UTF-8 iteration, not the raw byte. ASCII: byte
     * offset and codepoint coincide. */
    CHECK(lyric_string_char_at(a, 0) == 'h');
    CHECK(lyric_string_char_at(a, 4) == 'o');

    /* Multi-byte: "h\xC3\xA9llo" = "héllo" ("héllo"). Byte offset 1
     * is where the 2-byte U+00E9 (é) sequence starts; offset 3 is "l"
     * (the byte right after the 2-byte sequence, not offset 2). */
    LyricString* accented = lyric_string_from_literal((const uint8_t*)"h\xC3\xA9llo", 6);
    CHECK(lyric_string_char_at(accented, 0) == 'h');
    CHECK(lyric_string_char_at(accented, 1) == 0xE9);
    CHECK(lyric_string_char_at(accented, 3) == 'l');
    lyric_release(accented);

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

    /* .NET's default Double.ToString() / Single.ToString() rendering: the
     * shortest round-tripping digits, fixed notation for decimal exponents
     * -4 ..= 16 (Double) or -4 ..= 8 (Float), scientific otherwise (D155). */
    CHECK(string_is(lyric_string_from_float(0.1 + 0.2), "0.30000000000000004"));
    CHECK(string_is(lyric_string_from_float(1e16), "10000000000000000"));
    CHECK(string_is(lyric_string_from_float(1e17), "1E+17"));
    CHECK(string_is(lyric_string_from_float(1e15), "1000000000000000"));
    CHECK(string_is(lyric_string_from_float(1e-5), "1E-05"));
    CHECK(string_is(lyric_string_from_float(0.0001), "0.0001"));
    CHECK(string_is(lyric_string_from_float(1.0 / 3.0), "0.3333333333333333"));
    CHECK(string_is(lyric_string_from_float(-0.0), "-0"));
    CHECK(string_is(lyric_string_from_float(1500.0), "1500"));
    CHECK(string_is(lyric_string_from_float(123.456), "123.456"));
    CHECK(string_is(lyric_string_from_float(5e-324), "5E-324"));
    CHECK(string_is(lyric_string_from_float(1.7976931348623157e308), "1.7976931348623157E+308"));
    CHECK(string_is(lyric_string_from_float(-2.5e-7), "-2.5E-07"));
    CHECK(string_is(lyric_string_from_float32(0.3f), "0.3"));
    CHECK(string_is(lyric_string_from_float32(16777216.0f), "16777216"));
    CHECK(string_is(lyric_string_from_float32(1.0f / 3.0f), "0.33333334"));
    CHECK(string_is(lyric_string_from_float32(1e7f), "10000000"));
    CHECK(string_is(lyric_string_from_float32(1.234567e7f), "12345670"));
    CHECK(string_is(lyric_string_from_float32(1e8f), "100000000"));
    CHECK(string_is(lyric_string_from_float32(1e9f), "1E+09"));
    CHECK(string_is(lyric_string_from_float32(123456789.0f), "123456790"));
    CHECK(string_is(lyric_string_from_float32(1e-4f), "0.0001"));
    CHECK(string_is(lyric_string_from_float32(1e-5f), "1E-05"));
    CHECK(string_is(lyric_string_from_float32(3.4028235e38f), "3.4028235E+38"));
    CHECK(string_is(lyric_string_from_float32(1.401298e-45f), "1E-45"));
    CHECK(string_is(lyric_string_from_float32(1.17549435e-38f), "1.1754944E-38"));
    CHECK(string_is(lyric_string_from_float32(0.1f), "0.1"));
    CHECK(string_is(lyric_string_from_float32(123456.7f), "123456.7"));
    CHECK(string_is(lyric_string_from_float32(-0.0f), "-0"));
    CHECK(string_is(lyric_string_from_float32(0.1f + 0.2f), "0.3"));
    /* Next to a power of two the rounding interval is lopsided: the nearest
     * p-digit decimal falls outside it and .NET picks its neighbour
     * (2^-24 and two binary32 bit patterns); an exact tie goes to the even
     * digit, as .NET does (63769.3125f is "63769.312"). */
    CHECK(string_is(lyric_string_from_float32(63769.3125f), "63769.312"));
    CHECK(string_is(lyric_string_from_float32(3000970.25f), "3000970.2"));
    CHECK(string_is(lyric_string_from_float(5.9604644775390625e-08), "5.960464477539063E-08"));
    CHECK(string_is(lyric_string_from_float(3.0517578125e-05), "3.0517578125E-05"));
    {
        union { uint32_t u; float f; } b1 = { 1795162112u }, b2 = { 260046848u };
        CHECK(string_is(lyric_string_from_float32(b1.f), "1.5474251E+26"));
        CHECK(string_is(lyric_string_from_float32(b2.f), "1.2621775E-29"));
    }

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

/* Trim / case-conversion / search intrinsics behind `.trim()`, `.toLower()`,
 * `.indexOf()`, `.lastIndexOf()`, `.startsWith()`, `.contains()`,
 * `.endsWith()` (#6588, #6755), `.trimStart()`, `.trimEnd()`, and
 * `.replace()` (#6240), plus `.toUpper()` and the widened full-UCD
 * `.toLower()`/`.toUpper()` script coverage (#6779). */
static void test_string_trim_case_search(void) {
    LyricString* padded = lyric_string_from_literal((const uint8_t*)"  hi there  ", 12);
    LyricString* trimmed = lyric_string_trim(padded);
    CHECK(lyric_string_len(trimmed) == 8);
    CHECK(memcmp(LYRIC_STRING_DATA(trimmed), "hi there", 8) == 0);

    LyricString* allSpace = lyric_string_from_literal((const uint8_t*)"   ", 3);
    LyricString* trimmedEmpty = lyric_string_trim(allSpace);
    CHECK(lyric_string_len(trimmedEmpty) == 0);

    LyricString* noPad = lyric_string_from_literal((const uint8_t*)"clean", 5);
    LyricString* trimmedNoPad = lyric_string_trim(noPad);
    CHECK(lyric_string_len(trimmedNoPad) == 5);
    CHECK(memcmp(LYRIC_STRING_DATA(trimmedNoPad), "clean", 5) == 0);

    LyricString* empty0 = lyric_string_from_literal((const uint8_t*)"", 0);
    LyricString* trimmedEmpty0 = lyric_string_trim(empty0);
    CHECK(lyric_string_len(trimmedEmpty0) == 0);

    /* U+00A0 NO-BREAK SPACE (UTF-8 0xC2 0xA0) on both sides of "x" — a
     * Unicode whitespace code point ASCII-only trimming would miss. */
    LyricString* nbsp = lyric_string_from_literal((const uint8_t*)"\xC2\xA0x\xC2\xA0", 5);
    LyricString* nbspTrimmed = lyric_string_trim(nbsp);
    CHECK(lyric_string_len(nbspTrimmed) == 1);
    CHECK(memcmp(LYRIC_STRING_DATA(nbspTrimmed), "x", 1) == 0);

    /* .trimStart() / .trimEnd() (#6240): one-sided variants sharing
     * .trim()'s White_Space set and Unicode-aware nbsp handling. */
    LyricString* trimStarted = lyric_string_trim_start(padded);
    CHECK(lyric_string_len(trimStarted) == 10);
    CHECK(memcmp(LYRIC_STRING_DATA(trimStarted), "hi there  ", 10) == 0);
    LyricString* trimEnded = lyric_string_trim_end(padded);
    CHECK(lyric_string_len(trimEnded) == 10);
    CHECK(memcmp(LYRIC_STRING_DATA(trimEnded), "  hi there", 10) == 0);
    LyricString* allSpaceStart = lyric_string_trim_start(allSpace);
    CHECK(lyric_string_len(allSpaceStart) == 0);
    LyricString* allSpaceEnd = lyric_string_trim_end(allSpace);
    CHECK(lyric_string_len(allSpaceEnd) == 0);
    LyricString* noPadStart = lyric_string_trim_start(noPad);
    CHECK(lyric_string_len(noPadStart) == 5);
    CHECK(memcmp(LYRIC_STRING_DATA(noPadStart), "clean", 5) == 0);
    LyricString* noPadEnd = lyric_string_trim_end(noPad);
    CHECK(lyric_string_len(noPadEnd) == 5);
    CHECK(memcmp(LYRIC_STRING_DATA(noPadEnd), "clean", 5) == 0);
    LyricString* nbspTrimStart = lyric_string_trim_start(nbsp);
    CHECK(lyric_string_len(nbspTrimStart) == 3);
    CHECK(memcmp(LYRIC_STRING_DATA(nbspTrimStart), "x\xC2\xA0", 3) == 0);
    LyricString* nbspTrimEnd = lyric_string_trim_end(nbsp);
    CHECK(lyric_string_len(nbspTrimEnd) == 3);
    CHECK(memcmp(LYRIC_STRING_DATA(nbspTrimEnd), "\xC2\xA0x", 3) == 0);

    /* .toLower(): ASCII, then three non-Latin/accented scripts proving this
     * is not a naive ASCII-only implementation. */
    LyricString* asciiUp = lyric_string_from_literal((const uint8_t*)"HELLO 123!", 10);
    LyricString* asciiLow = lyric_string_to_lower(asciiUp);
    CHECK(lyric_string_len(asciiLow) == 10);
    CHECK(memcmp(LYRIC_STRING_DATA(asciiLow), "hello 123!", 10) == 0);

    /* "CAF\xC3\x89" = "CAFÉ" (É = U+00C9) -> "caf\xC3\xA9" = "café" (é = U+00E9). */
    LyricString* cafeUp = lyric_string_from_literal((const uint8_t*)"CAF\xC3\x89", 5);
    LyricString* cafeLow = lyric_string_to_lower(cafeUp);
    CHECK(lyric_string_len(cafeLow) == 5);
    CHECK(memcmp(LYRIC_STRING_DATA(cafeLow), "caf\xC3\xA9", 5) == 0);

    /* Greek Α Β Γ (U+0391 U+0392 U+0393) -> α β γ (U+03B1 U+03B2 U+03B3). */
    LyricString* greekUp = lyric_string_from_literal((const uint8_t*)"\xCE\x91\xCE\x92\xCE\x93", 6);
    LyricString* greekLow = lyric_string_to_lower(greekUp);
    CHECK(lyric_string_len(greekLow) == 6);
    CHECK(memcmp(LYRIC_STRING_DATA(greekLow), "\xCE\xB1\xCE\xB2\xCE\xB3", 6) == 0);

    /* Cyrillic А Б В (U+0410 U+0411 U+0412) -> а б в (U+0430 U+0431 U+0432). */
    LyricString* cyrUp = lyric_string_from_literal((const uint8_t*)"\xD0\x90\xD0\x91\xD0\x92", 6);
    LyricString* cyrLow = lyric_string_to_lower(cyrUp);
    CHECK(lyric_string_len(cyrLow) == 6);
    CHECK(memcmp(LYRIC_STRING_DATA(cyrLow), "\xD0\xB0\xD0\xB1\xD0\xB2", 6) == 0);

    /* U+0130 (İ, LATIN CAPITAL LETTER I WITH DOT ABOVE, UTF-8 0xC4 0xB0)
     * has its OWN unconditional simple lowercase mapping to plain ASCII
     * U+0069 ("i"), NOT U+0131 (ı, dotless small i) -- the two are not
     * case-partners despite both falling inside Latin Extended-A's
     * otherwise-uniform even/odd pairing (#6758). This is also the one
     * mapping that shrinks the UTF-8 byte length (2 bytes -> 1),
     * exercising lyric_string_to_lower's compacting write loop. */
    LyricString* dottedIUp = lyric_string_from_literal((const uint8_t*)"\xC4\xB0", 2);
    LyricString* dottedILow = lyric_string_to_lower(dottedIUp);
    CHECK(lyric_string_len(dottedILow) == 1);
    CHECK(memcmp(LYRIC_STRING_DATA(dottedILow), "i", 1) == 0);

    /* Embedded mid-string ("İstanbul" -> "istanbul") proves the shrink's
     * compaction shift doesn't corrupt the bytes that follow it. */
    LyricString* istanbulUp = lyric_string_from_literal((const uint8_t*)"\xC4\xB0stanbul", 9);
    LyricString* istanbulLow = lyric_string_to_lower(istanbulUp);
    CHECK(lyric_string_len(istanbulLow) == 8);
    CHECK(memcmp(LYRIC_STRING_DATA(istanbulLow), "istanbul", 8) == 0);

    LyricString* alreadyLow = lyric_string_from_literal((const uint8_t*)"already-lower!", 14);
    LyricString* stillLow = lyric_string_to_lower(alreadyLow);
    CHECK(lyric_string_len(stillLow) == 14);
    CHECK(memcmp(LYRIC_STRING_DATA(stillLow), "already-lower!", 14) == 0);

    LyricString* emptyLower = lyric_string_to_lower(empty0);
    CHECK(lyric_string_len(emptyLower) == 0);

    /* #6779: widened Unicode Character Database script coverage beyond the
     * five scripts above (Basic Latin, Latin-1 Supplement, Latin
     * Extended-A, Greek, Cyrillic) — Armenian and Georgian, neither of
     * which existed in the pre-#6779 hand-written table at all. */
    LyricString* armUp = lyric_string_from_literal((const uint8_t*)"\xD4\xB1\xD4\xB2", 4); /* Ա Բ */
    LyricString* armLow = lyric_string_to_lower(armUp);
    CHECK(lyric_string_len(armLow) == 4);
    CHECK(memcmp(LYRIC_STRING_DATA(armLow), "\xD5\xA1\xD5\xA2", 4) == 0); /* ա բ */
    /* Georgian Mkhedruli ა (U+10D0) uppercases to Mtavruli Ა (U+1C90, the
     * Unicode 11.0+ case pairing) per UnicodeData.txt's own simple
     * uppercase mapping field — NOT the historical Asomtavruli block
     * (U+10A0), which has no case relationship encoded there. */
    LyricString* geoLow = lyric_string_from_literal((const uint8_t*)"\xE1\x83\x90", 3); /* ა (Mkhedruli) */
    LyricString* geoUp = lyric_string_to_upper(geoLow);
    CHECK(lyric_string_len(geoUp) == 3);
    CHECK(memcmp(LYRIC_STRING_DATA(geoUp), "\xE1\xB2\x90", 3) == 0); /* Ⴑ (Mtavruli, U+1C90) */

    /* #6779: the full UCD table maps some pairs to a DIFFERENT UTF-8 byte
     * length than the old five-script table ever produced (which only
     * ever shrank, and only for U+0130) — in BOTH directions. U+212A
     * KELVIN SIGN (3 bytes) lowercases to plain ASCII "k" (1 byte): a
     * 3->1 shrink. U+023A Ⱥ (2 bytes) lowercases to U+2C65 ⱥ (3 bytes): a
     * 2->3 GROW the old single-pass "allocate at input length" strategy
     * could never have handled safely — the two-pass length computation
     * in string_case_map exists specifically for cases like this one. */
    LyricString* kelvin = lyric_string_from_literal((const uint8_t*)"\xE2\x84\xAA", 3);
    LyricString* kelvinLow = lyric_string_to_lower(kelvin);
    CHECK(lyric_string_len(kelvinLow) == 1);
    CHECK(memcmp(LYRIC_STRING_DATA(kelvinLow), "k", 1) == 0);
    LyricString* strokeAUp = lyric_string_from_literal((const uint8_t*)"\xC8\xBA", 2);
    LyricString* strokeALow = lyric_string_to_lower(strokeAUp);
    CHECK(lyric_string_len(strokeALow) == 3);
    CHECK(memcmp(LYRIC_STRING_DATA(strokeALow), "\xE2\xB1\xA5", 3) == 0);
    /* Roundtrip: uppercasing the grown lowercase form gives back the
     * original 2-byte uppercase letter (a shrink in the .toUpper() direction). */
    LyricString* strokeARound = lyric_string_to_upper(strokeALow);
    CHECK(lyric_string_len(strokeARound) == 2);
    CHECK(memcmp(LYRIC_STRING_DATA(strokeARound), "\xC8\xBA", 2) == 0);

    /* .toUpper() (#6779, previously native-unimplemented entirely): ASCII,
     * a no-op on an already-uppercase/no-case-partner input (U+0130 İ has
     * no further uppercase mapping — its own uppercase IS itself), and
     * empty. */
    LyricString* upAsciiLow = lyric_string_from_literal((const uint8_t*)"hello 123!", 10);
    LyricString* upAsciiUp = lyric_string_to_upper(upAsciiLow);
    CHECK(lyric_string_len(upAsciiUp) == 10);
    CHECK(memcmp(LYRIC_STRING_DATA(upAsciiUp), "HELLO 123!", 10) == 0);
    LyricString* dottedIUpNoop = lyric_string_to_upper(dottedIUp);
    CHECK(lyric_string_len(dottedIUpNoop) == 2);
    CHECK(memcmp(LYRIC_STRING_DATA(dottedIUpNoop), "\xC4\xB0", 2) == 0);
    LyricString* emptyUpper = lyric_string_to_upper(empty0);
    CHECK(lyric_string_len(emptyUpper) == 0);

    /* .indexOf(): found, not-found (-1 sentinel), and empty-needle/-haystack. */
    LyricString* haystack = lyric_string_from_literal((const uint8_t*)"hello world", 11);
    LyricString* needleFound = lyric_string_from_literal((const uint8_t*)"world", 5);
    LyricString* needleMissing = lyric_string_from_literal((const uint8_t*)"xyz", 3);
    LyricString* helloOnly = lyric_string_from_literal((const uint8_t*)"hello", 5);
    CHECK(lyric_string_index_of(haystack, needleFound) == 6);
    CHECK(lyric_string_index_of(haystack, needleMissing) == -1);
    CHECK(lyric_string_index_of(haystack, empty0) == 0);
    CHECK(lyric_string_index_of(empty0, needleFound) == -1);
    CHECK(lyric_string_index_of(empty0, empty0) == 0);
    CHECK(lyric_string_index_of(haystack, helloOnly) == 0);

    /* .contains() shares indexOf's sentinel semantics. */
    CHECK(lyric_string_contains(haystack, needleFound));
    CHECK(!lyric_string_contains(haystack, needleMissing));
    CHECK(lyric_string_contains(haystack, empty0));

    /* .lastIndexOf(): a repeated needle finds the LAST occurrence (unlike
     * .indexOf()'s first), not-found (-1 sentinel), and the empty-needle
     * case matches at haystack.length (not 0), mirroring the dotnet/JVM
     * twins' LastIndexOf("")/lastIndexOf(""). */
    LyricString* repeated = lyric_string_from_literal((const uint8_t*)"hello world hello", 17);
    LyricString* helloNeedle = lyric_string_from_literal((const uint8_t*)"hello", 5);
    CHECK(lyric_string_last_index_of(repeated, helloNeedle) == 12);
    CHECK(lyric_string_index_of(repeated, helloNeedle) == 0);
    CHECK(lyric_string_last_index_of(repeated, empty0) == (int64_t)lyric_string_len(repeated));
    CHECK(lyric_string_last_index_of(haystack, needleFound) == 6);
    CHECK(lyric_string_last_index_of(haystack, needleMissing) == -1);
    CHECK(lyric_string_last_index_of(haystack, empty0) == (int64_t)lyric_string_len(haystack));
    CHECK(lyric_string_last_index_of(empty0, needleFound) == -1);
    CHECK(lyric_string_last_index_of(empty0, empty0) == 0);
    CHECK(lyric_string_last_index_of(haystack, helloOnly) == 0);

    /* .startsWith() / .endsWith(): match, mismatch, over-length needle, and
     * the empty-prefix/-suffix edge case (always true). */
    LyricString* worldSuffix = lyric_string_from_literal((const uint8_t*)"world", 5);
    LyricString* wrongPrefix = lyric_string_from_literal((const uint8_t*)"world", 5);
    LyricString* tooLong = lyric_string_from_literal((const uint8_t*)"hello world!", 12);
    CHECK(lyric_string_starts_with(haystack, helloOnly));
    CHECK(!lyric_string_starts_with(haystack, wrongPrefix));
    CHECK(!lyric_string_starts_with(haystack, tooLong));
    CHECK(lyric_string_starts_with(haystack, empty0));
    CHECK(lyric_string_ends_with(haystack, worldSuffix));
    CHECK(!lyric_string_ends_with(haystack, helloOnly));
    CHECK(!lyric_string_ends_with(haystack, tooLong));
    CHECK(lyric_string_ends_with(haystack, empty0));

    /* .replace() (#6240): all non-overlapping occurrences, left to right;
     * shrinking/growing replacements, no match, and the empty-oldValue
     * no-op (this runtime's own deliberate choice — see lyric_string.c). */
    LyricString* repl = lyric_string_from_literal((const uint8_t*)"aXbXcX", 6);
    LyricString* replOld = lyric_string_from_literal((const uint8_t*)"X", 1);
    LyricString* replNewLonger = lyric_string_from_literal((const uint8_t*)"YY", 2);
    LyricString* replaced = lyric_string_replace(repl, replOld, replNewLonger);
    CHECK(lyric_string_len(replaced) == 9);
    CHECK(memcmp(LYRIC_STRING_DATA(replaced), "aYYbYYcYY", 9) == 0);
    LyricString* replNewEmpty = lyric_string_from_literal((const uint8_t*)"", 0);
    LyricString* replacedShrink = lyric_string_replace(repl, replOld, replNewEmpty);
    CHECK(lyric_string_len(replacedShrink) == 3);
    CHECK(memcmp(LYRIC_STRING_DATA(replacedShrink), "abc", 3) == 0);
    LyricString* replMissing = lyric_string_from_literal((const uint8_t*)"Z", 1);
    LyricString* replacedNoMatch = lyric_string_replace(repl, replMissing, replNewLonger);
    CHECK(lyric_string_len(replacedNoMatch) == 6);
    CHECK(memcmp(LYRIC_STRING_DATA(replacedNoMatch), "aXbXcX", 6) == 0);
    LyricString* replacedEmptyOld = lyric_string_replace(repl, empty0, replNewLonger);
    CHECK(lyric_string_len(replacedEmptyOld) == 6);
    CHECK(memcmp(LYRIC_STRING_DATA(replacedEmptyOld), "aXbXcX", 6) == 0);

    lyric_release(padded);
    lyric_release(trimmed);
    lyric_release(allSpace);
    lyric_release(trimmedEmpty);
    lyric_release(noPad);
    lyric_release(trimmedNoPad);
    lyric_release(empty0);
    lyric_release(trimmedEmpty0);
    lyric_release(nbsp);
    lyric_release(nbspTrimmed);
    lyric_release(trimStarted);
    lyric_release(trimEnded);
    lyric_release(allSpaceStart);
    lyric_release(allSpaceEnd);
    lyric_release(noPadStart);
    lyric_release(noPadEnd);
    lyric_release(nbspTrimStart);
    lyric_release(nbspTrimEnd);
    lyric_release(repl);
    lyric_release(replOld);
    lyric_release(replNewLonger);
    lyric_release(replaced);
    lyric_release(replNewEmpty);
    lyric_release(replacedShrink);
    lyric_release(replMissing);
    lyric_release(replacedNoMatch);
    lyric_release(replacedEmptyOld);
    lyric_release(asciiUp);
    lyric_release(asciiLow);
    lyric_release(cafeUp);
    lyric_release(cafeLow);
    lyric_release(greekUp);
    lyric_release(greekLow);
    lyric_release(cyrUp);
    lyric_release(cyrLow);
    lyric_release(dottedIUp);
    lyric_release(dottedILow);
    lyric_release(istanbulUp);
    lyric_release(istanbulLow);
    lyric_release(alreadyLow);
    lyric_release(stillLow);
    lyric_release(emptyLower);
    lyric_release(armUp);
    lyric_release(armLow);
    lyric_release(geoLow);
    lyric_release(geoUp);
    lyric_release(kelvin);
    lyric_release(kelvinLow);
    lyric_release(strokeAUp);
    lyric_release(strokeALow);
    lyric_release(strokeARound);
    lyric_release(upAsciiLow);
    lyric_release(upAsciiUp);
    lyric_release(dottedIUpNoop);
    lyric_release(emptyUpper);
    lyric_release(haystack);
    lyric_release(needleFound);
    lyric_release(needleMissing);
    lyric_release(helloOnly);
    lyric_release(worldSuffix);
    lyric_release(wrongPrefix);
    lyric_release(tooLong);
    lyric_release(repeated);
    lyric_release(helloNeedle);
}

static void test_string_index_of_from_concat_list(void) {
    /* indexOfFrom (#7258): matches at/after `from`, -1 when absent after it,
     * empty needle matches at `from` (including from == length), and a
     * match that starts exactly at `from`. */
    LyricString* h = lyric_string_from_literal((const uint8_t*)"a,b,,c", 6);
    LyricString* comma = lyric_string_from_literal((const uint8_t*)",", 1);
    LyricString* empty = lyric_string_from_literal((const uint8_t*)"", 0);
    LyricString* bc = lyric_string_from_literal((const uint8_t*)"b,", 2);
    CHECK(lyric_string_index_of_from(h, comma, 0) == 1);
    CHECK(lyric_string_index_of_from(h, comma, 1) == 1);
    CHECK(lyric_string_index_of_from(h, comma, 2) == 3);
    CHECK(lyric_string_index_of_from(h, comma, 4) == 4);
    CHECK(lyric_string_index_of_from(h, comma, 5) == -1);
    CHECK(lyric_string_index_of_from(h, comma, 6) == -1);
    CHECK(lyric_string_index_of_from(h, empty, 3) == 3);
    CHECK(lyric_string_index_of_from(h, empty, 6) == 6);
    CHECK(lyric_string_index_of_from(h, bc, 0) == 2);
    CHECK(lyric_string_index_of_from(h, bc, 3) == -1);
    /* A partial-prefix candidate before the real match exercises the
     * memchr-skip loop's retry path. */
    LyricString* aab = lyric_string_from_literal((const uint8_t*)"aaab", 4);
    LyricString* ab = lyric_string_from_literal((const uint8_t*)"ab", 2);
    CHECK(lyric_string_index_of(aab, ab) == 2);
    CHECK(lyric_string_index_of_from(aab, ab, 1) == 2);
    CHECK(lyric_string_index_of_from(aab, ab, 3) == -1);

    /* concat_list (#7257): empty list, single element, empty elements, and
     * multi-byte UTF-8 content copied verbatim. */
    LyricList* parts = lyric_list_new(1);
    LyricString* none = lyric_string_concat_list(parts);
    CHECK(lyric_string_len(none) == 0);
    lyric_list_push(parts, (int64_t)(intptr_t)h);
    lyric_list_push(parts, (int64_t)(intptr_t)empty);
    LyricString* utf8 = lyric_string_from_literal((const uint8_t*)"\xC3\xA9!", 3);
    lyric_list_push(parts, (int64_t)(intptr_t)utf8);
    LyricString* joined = lyric_string_concat_list(parts);
    CHECK(lyric_string_len(joined) == 9);
    CHECK(memcmp(LYRIC_STRING_DATA(joined), "a,b,,c\xC3\xA9!", 9) == 0);
    CHECK(LYRIC_STRING_DATA(joined)[9] == 0);

    lyric_release(joined);
    lyric_release(none);
    lyric_release(parts);
    lyric_release(utf8);
    lyric_release(ab);
    lyric_release(aab);
    lyric_release(bc);
    lyric_release(empty);
    lyric_release(comma);
    lyric_release(h);
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

/* Regression for #5504: a live weak reference must keep the header
 * allocation alive after the last strong ref is released, so upgrade()
 * reads a valid (== 0 -> dead) rc instead of freed memory.  Before the
 * fix the header carried no weak count and lyric_release freed the
 * allocation the instant rc hit 0, so this upgrade read freed memory
 * (a heap-use-after-free under ASan). */
static void test_weak_uaf(void) {
    LyricObjectHeader* h = (LyricObjectHeader*)lyric_alloc(sizeof(LyricObjectHeader));
    atomic_store(&h->rc, 1);
    lyric_weak_init(h);           /* weak = 1 (the implicit strong-side count) */
    h->dtor = counting_dtor;
    dtor_calls = 0;

    lyric_weak_retain(h);         /* take a weak reference: weak = 2 */

    /* Drop the last strong ref: the destructor runs and the implicit weak
     * count is dropped (weak = 1), but the allocation is NOT freed because
     * the outstanding weak reference still holds weak = 1. */
    lyric_release(h);
    CHECK(dtor_calls == 1);

    /* The object is dead (rc == 0) but the header is still allocated, so
     * upgrade returns NULL by reading a valid rc — not freed memory. */
    CHECK(lyric_weak_upgrade(h) == NULL);

    /* Dropping the last weak reference frees the allocation now. */
    lyric_weak_release(h);
    /* h is dangling past this point; do not dereference it. */
}

/* A weak reference upgrades to a strong reference while the object is
 * alive, and the whole two-count teardown runs cleanly. */
static void test_weak_liveness(void) {
    LyricObjectHeader* h = (LyricObjectHeader*)lyric_alloc(sizeof(LyricObjectHeader));
    atomic_store(&h->rc, 1);
    lyric_weak_init(h);
    h->dtor = counting_dtor;
    dtor_calls = 0;

    lyric_weak_retain(h);              /* weak = 2 */
    void* up = lyric_weak_upgrade(h);  /* alive: rc 1 -> 2 */
    CHECK(up == h);
    CHECK(atomic_load(&h->rc) == 2);
    lyric_release(h);                  /* rc 2 -> 1 */
    CHECK(dtor_calls == 0);
    lyric_release(h);                  /* rc 1 -> 0: dtor runs, weak 2 -> 1 */
    CHECK(dtor_calls == 1);
    lyric_weak_release(h);             /* weak 1 -> 0: freed */
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

/* Steady set/remove churn of distinct keys keeps the live size small but
 * accumulates tombstones.  The resize path now rehashes in place to purge
 * tombstones instead of doubling capacity forever; this exercises that path
 * and asserts the map stays correct across many churn cycles. */
static void test_map_tombstone_churn(void) {
    LyricMap* m = lyric_map_new(0, 0);
    /* Seed ~64 live entries. */
    for (int64_t i = 0; i < 64; i++) lyric_map_set(m, i, i);
    CHECK(lyric_map_len(m) == 64);
    /* Remove the oldest key and add a fresh distinct key, 20000 times.  The
     * live size stays 64 throughout; without the in-place-rehash fix this
     * churn would ratchet capacity up unboundedly. */
    for (int64_t step = 0; step < 20000; step++) {
        int64_t removed = step;
        int64_t added = 64 + step;
        CHECK(lyric_map_remove(m, removed));
        lyric_map_set(m, added, added * 2);
        CHECK(lyric_map_len(m) == 64);
    }
    /* The most-recent 64 keys are present with correct values; older ones gone. */
    int64_t v = 0;
    CHECK(lyric_map_get(m, 64 + 19999, &v) && v == (64 + 19999) * 2);
    CHECK(!lyric_map_get(m, 0, &v));
    CHECK(!lyric_map_get(m, 63, &v));
    CHECK(lyric_map_len(m) == 64);
    /* The property under test: 64 live entries need only ~128-slot capacity;
     * the in-place-rehash fix must keep capacity bounded across 20000 churn
     * cycles.  Without it, each set past the load-factor threshold would
     * double capacity (tombstones counted as `used`), ratcheting cap into the
     * hundreds of thousands.  A generous 4096 ceiling still fails hard on that
     * regression while leaving headroom for the legitimate ~128-256 range. */
    CHECK(lyric_map_cap(m) <= 4096);
    lyric_release(m);
}

/* Removing most entries shrinks capacity back toward the live size, so a
 * key/value snapshot after a mass removal is O(live), and the survivors keep
 * their values across the shrinking rehashes (#7282). */
static void test_map_shrinks_on_removal(void) {
    LyricMap* m = lyric_map_new(0, 0);
    for (int64_t i = 0; i < 100000; i++) lyric_map_set(m, i, i + 1);
    int64_t peak = lyric_map_cap(m);
    CHECK(peak >= 131072);
    for (int64_t i = 0; i < 100000; i++) {
        if (i % 1000 != 0) CHECK(lyric_map_remove(m, i));
    }
    CHECK(lyric_map_len(m) == 100);
    CHECK(lyric_map_cap(m) <= 256);
    int64_t v = 0;
    for (int64_t i = 0; i < 100000; i += 1000) {
        CHECK(lyric_map_get(m, i, &v) && v == i + 1);
    }
    CHECK(!lyric_map_get(m, 1, &v));
    LyricList* ks = lyric_map_keys(m);
    CHECK(lyric_list_len(ks) == 100);
    lyric_release(ks);
    /* Draining to empty keeps the minimum table; refilling still works. */
    for (int64_t i = 0; i < 100000; i += 1000) CHECK(lyric_map_remove(m, i));
    CHECK(lyric_map_len(m) == 0);
    CHECK(lyric_map_cap(m) == 16);
    for (int64_t i = 0; i < 50; i++) lyric_map_set(m, i, i);
    CHECK(lyric_map_len(m) == 50);
    CHECK(lyric_map_get(m, 49, &v) && v == 49);
    lyric_release(m);
}

/* A tombstone purge inside lyric_map_set also fits the table: when churn
 * forces the purge while the live set is far below capacity (no removal
 * crossed the 1/8 shrink line first), the rehash lands on the fitted size
 * rather than the current capacity. */
static void test_map_set_purge_shrinks(void) {
    LyricMap* m = lyric_map_new(0, 0);
    /* 90 live entries sit in 128 slots.  Removing down to 20 keeps
     * 20*8 = 160 >= 128, so no remove-triggered shrink fires, but the
     * fitted size for 21 entries is 64. */
    for (int64_t i = 0; i < 90; i++) lyric_map_set(m, i, i);
    CHECK(lyric_map_cap(m) == 128);
    for (int64_t i = 20; i < 90; i++) CHECK(lyric_map_remove(m, i));
    CHECK(lyric_map_len(m) == 20);
    CHECK(lyric_map_cap(m) == 128);
    /* FIFO churn over the live window [lo, hi) at a constant size of 20
     * until the tombstones push `used` past 3/4 of capacity and
     * lyric_map_set purges. */
    int64_t lo = 0, hi = 20;
    for (int step = 0; step < 100000 && lyric_map_cap(m) == 128; step++) {
        CHECK(lyric_map_remove(m, lo));
        lo++;
        lyric_map_set(m, hi, hi * 3);
        hi++;
    }
    CHECK(lyric_map_cap(m) == 64);
    CHECK(lyric_map_len(m) == 20);
    int64_t v = 0;
    for (int64_t k = lo; k < hi; k++) CHECK(lyric_map_get(m, k, &v) && v == k * 3);
    CHECK(!lyric_map_get(m, lo - 1, &v));
    lyric_release(m);
}

/* lyric_list_append_all appends in place: scalar bytes keep order and
 * value, ref elements are retained by the destination, and appending a
 * list to itself doubles it (#7269). */
static void test_list_append_all(void) {
    const uint8_t a[] = {1, 2, 3};
    const uint8_t b[] = {250, 251};
    LyricList* dst = lyric_list_from_bytes(a, 3);
    LyricList* src = lyric_list_from_bytes(b, 2);
    lyric_list_append_all(dst, src);
    CHECK(lyric_list_len(dst) == 5);
    CHECK(lyric_list_get(dst, 2) == 3);
    CHECK(lyric_list_get(dst, 4) == 251);
    CHECK(lyric_list_len(src) == 2);
    lyric_list_append_all(dst, dst);
    CHECK(lyric_list_len(dst) == 10);
    CHECK(lyric_list_get(dst, 5) == 1);
    CHECK(lyric_list_get(dst, 9) == 251);
    LyricList* empty = lyric_list_new(0);
    lyric_list_append_all(dst, empty);
    CHECK(lyric_list_len(dst) == 10);
    lyric_release(empty);
    lyric_release(src);
    lyric_release(dst);

    LyricList* rd = lyric_list_new(1);
    LyricList* rs = lyric_list_new(1);
    LyricString* x = lyric_string_from_literal((const uint8_t*)"x", 1);
    lyric_list_push(rs, (int64_t)(intptr_t)x);
    lyric_release(x);
    lyric_list_append_all(rd, rs);
    CHECK(atomic_load(&x->rc) == 2);
    lyric_list_append_all(rd, rd);
    CHECK(lyric_list_len(rd) == 2);
    CHECK(atomic_load(&x->rc) == 3);
    lyric_release(rs);
    lyric_release(rd);
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

static void test_list_bulk_builders(void) {
    /* lyric_list_from_bytes / lyric_string_utf8_bytes (#7282, #7271). */
    const uint8_t raw[] = {0, 1, 200, 255};
    LyricList* bytes = lyric_list_from_bytes(raw, 4);
    CHECK(lyric_list_len(bytes) == 4);
    CHECK(lyric_list_get(bytes, 2) == 200);
    CHECK(lyric_list_get(bytes, 3) == 255);
    lyric_list_push(bytes, 9); /* still growable */
    CHECK(lyric_list_len(bytes) == 5);
    lyric_release(bytes);
    LyricString* s = lyric_string_from_literal((const uint8_t*)"h\xc3\xa9", 3);
    LyricList* utf8 = lyric_string_utf8_bytes(s);
    CHECK(lyric_list_len(utf8) == 3);
    CHECK(lyric_list_get(utf8, 1) == 0xC3 && lyric_list_get(utf8, 2) == 0xA9);
    lyric_release(utf8);
    lyric_release(s);
    LyricList* none = lyric_string_utf8_bytes(NULL);
    CHECK(lyric_list_len(none) == 0);
    lyric_release(none);

    /* A ref-element concat across several growth steps retains every
     * element exactly once. */
    LyricString* e = lyric_string_from_literal((const uint8_t*)"x", 1);
    LyricList* a = lyric_list_new(1);
    LyricList* b = lyric_list_new(1);
    for (int i = 0; i < 20; i++) lyric_list_push(a, (int64_t)(intptr_t)e);
    for (int i = 0; i < 13; i++) lyric_list_push(b, (int64_t)(intptr_t)e);
    LyricList* ab = lyric_list_concat(a, b);
    CHECK(lyric_list_len(ab) == 33);
    CHECK(atomic_load(&e->rc) == 1 + 33 + 33);
    LyricList* mid = lyric_list_slice(ab, 5, 30);
    CHECK(lyric_list_len(mid) == 25);
    LyricList* more = lyric_list_append(mid, (int64_t)(intptr_t)e);
    CHECK(lyric_list_len(more) == 26);
    lyric_release(a);
    lyric_release(b);
    lyric_release(ab);
    lyric_release(mid);
    lyric_release(more);
    CHECK(atomic_load(&e->rc) == 1);
    lyric_release(e);
}

static void test_list_slice_concat_append(void) {
    /* `.slice(start, stop)`: a fresh half-open sub-copy. Ref elements are
     * retained by the new list; the source is untouched. */
    LyricList* src = lyric_list_new(1);
    LyricString* a = lyric_string_from_literal((const uint8_t*)"a", 1);
    LyricString* b = lyric_string_from_literal((const uint8_t*)"b", 1);
    LyricString* c = lyric_string_from_literal((const uint8_t*)"c", 1);
    lyric_list_push(src, (int64_t)(intptr_t)a);
    lyric_list_push(src, (int64_t)(intptr_t)b);
    lyric_list_push(src, (int64_t)(intptr_t)c);
    lyric_release(a);
    lyric_release(b);
    lyric_release(c);

    LyricList* mid = lyric_list_slice(src, 1, 2);
    CHECK(lyric_list_len(mid) == 1);
    CHECK((LyricString*)(intptr_t)lyric_list_get(mid, 0) == b);
    CHECK(atomic_load(&b->rc) == 2); /* held by src and mid */
    lyric_release(mid);
    CHECK(atomic_load(&b->rc) == 1);

    LyricList* empty_slice = lyric_list_slice(src, 1, 1);
    CHECK(lyric_list_len(empty_slice) == 0);
    lyric_release(empty_slice);

    LyricList* whole = lyric_list_slice(src, 0, 3);
    CHECK(lyric_list_len(whole) == 3);
    lyric_release(whole);

    /* `.concat(other)`: a fresh list holding every element of both,
     * neither input mutated. */
    LyricList* nums1 = lyric_list_new(0);
    lyric_list_push(nums1, 1);
    lyric_list_push(nums1, 2);
    LyricList* nums2 = lyric_list_new(0);
    lyric_list_push(nums2, 3);
    LyricList* joined = lyric_list_concat(nums1, nums2);
    CHECK(lyric_list_len(joined) == 3);
    CHECK(lyric_list_get(joined, 0) == 1);
    CHECK(lyric_list_get(joined, 1) == 2);
    CHECK(lyric_list_get(joined, 2) == 3);
    CHECK(lyric_list_len(nums1) == 2); /* inputs untouched */
    CHECK(lyric_list_len(nums2) == 1);
    lyric_release(joined);
    lyric_release(nums1);
    lyric_release(nums2);

    /* `.append(x)`: a fresh copy of `src` with `x` on the end, `src`
     * itself untouched (unlike `.add`/`lyric_list_push`). */
    LyricList* appendSrc = lyric_list_new(0);
    lyric_list_push(appendSrc, 10);
    LyricList* appended = lyric_list_append(appendSrc, 20);
    CHECK(lyric_list_len(appended) == 2);
    CHECK(lyric_list_get(appended, 0) == 10);
    CHECK(lyric_list_get(appended, 1) == 20);
    CHECK(lyric_list_len(appendSrc) == 1); /* source untouched */
    lyric_release(appended);
    lyric_release(appendSrc);

    lyric_release(src);
}

/* `.slice` out-of-bounds must panic (matching the MSIL/JVM twins'
 * "slice(start, end) requires 0 <= start <= end <= length" contract),
 * forked so the abort leaves no residue in the parent. One fork per
 * independent bounds condition (`start < 0`, `stop < start`, `stop >
 * length`) so a fix that only guards one of the three can't silently
 * regress the other two. */
#ifndef __wasi__
static void run_forked_slice_oob(int64_t start, int64_t stop) {
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        if (!freopen("/dev/null", "w", stderr)) _exit(9);
        LyricList* xs = lyric_list_new(0);
        lyric_list_push(xs, 1);
        LyricList* bad = lyric_list_slice(xs, start, stop);
        (void)bad;
        _exit(0); /* not reached */
    }
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_list_slice_oob_aborts(void) {
    run_forked_slice_oob(0, 5);  /* stop > len */
    run_forked_slice_oob(-1, 1); /* start < 0 */
    run_forked_slice_oob(1, 0);  /* stop < start */
}
#endif /* !__wasi__ */

/* `s[i]` (#6237) out-of-bounds must panic, mirroring `lyric_string_byte_at`'s
 * existing bounds check; forked so the abort leaves no residue in the
 * parent (same pattern as `run_forked_slice_oob`).  D-progress-1006: an
 * offset that does not start a BMP character (a continuation byte, a
 * supplementary-plane sequence, a CESU-encoded surrogate) panics the same
 * way, since no `Char` can hold it. */
#ifndef __wasi__
static void run_forked_char_at_abort(const char* bytes, int64_t n, int64_t idx) {
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        if (!freopen("/dev/null", "w", stderr)) _exit(9);
        LyricString* s = lyric_string_from_literal((const uint8_t*)bytes, n);
        int32_t bad = lyric_string_char_at(s, idx);
        (void)bad;
        _exit(0); /* not reached */
    }
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_string_char_at_oob_aborts(void) {
    run_forked_char_at_abort("hi", 2, -1); /* idx < 0 */
    run_forked_char_at_abort("hi", 2, 2);  /* idx == len */
    run_forked_char_at_abort("hi", 2, 99); /* idx > len */
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_string_char_at_non_bmp_aborts(void) {
    run_forked_char_at_abort("a\xF0\x9F\x98\x80", 5, 1); /* U+1F600 */
    run_forked_char_at_abort("h\xC3\xA9", 3, 2);           /* continuation byte */
    run_forked_char_at_abort("\xED\xA0\x80", 3, 0);        /* CESU surrogate U+D800 */
    /* The BMP neighbours still decode. */
    LyricString* s = lyric_string_from_literal((const uint8_t*)"a\xF0\x9F\x98\x80\xEF\xBF\xBF", 8);
    CHECK(lyric_string_char_at(s, 0) == 'a');
    CHECK(lyric_string_char_at(s, 5) == 0xFFFF);
    CHECK(lyric_string_byte_at(s, 1) == 0xF0);
    lyric_release(s);
}
#endif /* !__wasi__ */

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

/* Points fd 0 at a fresh pipe and returns the saved original stdin. */
#ifndef __wasi__
static int stdin_from_pipe(int* write_end) {
    int fds[2];
    CHECK(pipe(fds) == 0);
    int saved = dup(STDIN_FILENO);
    CHECK(saved >= 0);
    CHECK(dup2(fds[0], STDIN_FILENO) == STDIN_FILENO);
    close(fds[0]);
    *write_end = fds[1];
    return saved;
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_stdin_lines_and_bytes(void) {
    int w = -1;
    int saved = stdin_from_pipe(&w);
    const char* input = "ab\r\ncd\ref\ngh";
    CHECK(write(w, input, strlen(input)) == (ssize_t)strlen(input));
    close(w);

    CHECK(lyric_stdin_wait(0) == 1);
    LyricString* line = NULL;
    CHECK(lyric_stdin_read_line(&line) == 1);
    CHECK(string_is(line, "ab"));
    lyric_release(line);
    /* A lone '\r' ends the line; the byte after it is kept for the next read. */
    CHECK(lyric_stdin_read_line(&line) == 1);
    CHECK(string_is(line, "cd"));
    lyric_release(line);
    CHECK(lyric_stdin_wait(0) == 1);
    int32_t ok = 0;
    LyricList* bytes = lyric_stdin_read(16, &ok);
    CHECK(ok == 1);
    CHECK(lyric_list_len(bytes) == 1);
    CHECK(lyric_list_get(bytes, 0) == 'e');
    lyric_release(bytes);
    CHECK(lyric_stdin_read_line(&line) == 1);
    CHECK(string_is(line, "f"));
    lyric_release(line);
    /* A final line with no terminator is still a line. */
    CHECK(lyric_stdin_read_line(&line) == 1);
    CHECK(string_is(line, "gh"));
    lyric_release(line);
    CHECK(lyric_stdin_read_line(&line) == 0);
    /* End of stream: ready at once, and an empty read. */
    CHECK(lyric_stdin_wait(1000) == 1);
    ok = 0;
    bytes = lyric_stdin_read(16, &ok);
    CHECK(ok == 1);
    CHECK(lyric_list_len(bytes) == 0);
    lyric_release(bytes);

    CHECK(dup2(saved, STDIN_FILENO) == STDIN_FILENO);
    close(saved);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_stdin_wait_times_out(void) {
    int w = -1;
    int saved = stdin_from_pipe(&w);
    int64_t start = lyric_monotonic_nanos();
    CHECK(lyric_stdin_wait(60) == 0);
    int64_t waited_ms = (lyric_monotonic_nanos() - start) / 1000000;
    CHECK(waited_ms >= 50);
    /* Bytes that arrive after a timeout are read in full by the next read. */
    CHECK(write(w, "late", 4) == 4);
    CHECK(lyric_stdin_wait(1000) == 1);
    int32_t ok = 0;
    LyricList* bytes = lyric_stdin_read(16, &ok);
    CHECK(ok == 1);
    CHECK(lyric_list_len(bytes) == 4);
    CHECK(lyric_list_get(bytes, 3) == 'e');
    lyric_release(bytes);
    close(w);
    CHECK(dup2(saved, STDIN_FILENO) == STDIN_FILENO);
    close(saved);
}
#endif /* !__wasi__ */

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

/* Linear scan for a kind-prefixed entry ("<digit><name>", see
 * lyric_dir_list_typed) by its bare name; readdir order is unspecified,
 * so tests look entries up by name instead of assuming a position.
 * Returns the LYRIC_DIRENT_* digit on a match, -1 if not found. */
#ifndef __wasi__
static int32_t find_entry_kind(LyricList* entries, const char* target) {
    int64_t n = lyric_list_len(entries);
    size_t target_len = strlen(target);
    for (int64_t i = 0; i < n; i++) {
        LyricString* s = (LyricString*)(intptr_t)lyric_list_get(entries, i);
        int64_t slen = lyric_string_len(s);
        if ((size_t)slen == target_len + 1 &&
            memcmp(LYRIC_STRING_DATA(s) + 1, target, target_len) == 0) {
            return (int32_t)(LYRIC_STRING_DATA(s)[0] - '0');
        }
    }
    return -1;
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_dir_list_typed(void) {
    /* Missing directory: same ok-flag protocol as lyric_dir_list2. */
    int32_t ok = 1;
    LyricList* missing = lyric_dir_list_typed("/definitely/missing/lyric-rt-dir-typed", &ok);
    CHECK(ok == 0);
    CHECK(lyric_list_len(missing) == 0);
    lyric_release(missing);

    char tmpl[] = "/tmp/lyric_rt_dir_typed_XXXXXX";
    CHECK(mkdtemp(tmpl) != NULL);

    /* file.txt: a regular file entry — DT_REG, classified with no stat(). */
    char filep[512];
    snprintf(filep, sizeof filep, "%s/file.txt", tmpl);
    FILE* f = fopen(filep, "w");
    CHECK(f != NULL);
    fclose(f);

    /* subdir: a directory entry — DT_DIR, classified with no stat(). */
    char subp[512];
    snprintf(subp, sizeof subp, "%s/subdir", tmpl);
    CHECK(mkdir(subp, 0755) == 0);

    /* link_to_file / link_to_dir: symlinks (DT_LNK) exercise the
     * following-stat() fallback that DT_UNKNOWN also takes — the
     * classification must match the TARGET's kind, exactly like
     * lyric_file_exists / lyric_dir_exists (both follow symlinks).
     * DT_UNKNOWN itself depends on filesystem support and can't be
     * forced portably from a test, but it shares this same fallback
     * branch in classify_dirent, so this exercises that code path. */
    char linkFile[512];
    snprintf(linkFile, sizeof linkFile, "%s/link_to_file", tmpl);
    CHECK(symlink(filep, linkFile) == 0);
    char linkDir[512];
    snprintf(linkDir, sizeof linkDir, "%s/link_to_dir", tmpl);
    CHECK(symlink(subp, linkDir) == 0);

    /* link_broken: a dangling symlink — DT_LNK, stat() fails, so it must
     * classify as OTHER, matching the original hostFileExists /
     * hostDirectoryExists behavior (both report false on a failed stat). */
    char linkBroken[512];
    snprintf(linkBroken, sizeof linkBroken, "%s/link_broken", tmpl);
    CHECK(symlink("/definitely/missing/lyric-rt-typed-target", linkBroken) == 0);

    int32_t ok2 = 0;
    LyricList* entries = lyric_dir_list_typed(tmpl, &ok2);
    CHECK(ok2 == 1);
    CHECK(lyric_list_len(entries) == 5);

    CHECK(find_entry_kind(entries, "file.txt") == LYRIC_DIRENT_REG);
    CHECK(find_entry_kind(entries, "subdir") == LYRIC_DIRENT_DIR);
    CHECK(find_entry_kind(entries, "link_to_file") == LYRIC_DIRENT_REG);
    CHECK(find_entry_kind(entries, "link_to_dir") == LYRIC_DIRENT_DIR);
    CHECK(find_entry_kind(entries, "link_broken") == LYRIC_DIRENT_OTHER);

    lyric_release(entries);
    unlink(linkBroken);
    unlink(linkDir);
    unlink(linkFile);
    unlink(filep);
    rmdir(subp);
    rmdir(tmpl);
}
#endif /* !__wasi__ */

#ifndef __wasi__
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
#endif /* !__wasi__ */

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

    /* Cached (#4857): repeated calls hand back the SAME LyricList
     * (extra-retained), not a fresh allocation each time — and an
     * outstanding ref from an earlier call stays valid even after
     * later calls release theirs. */
    LyricList* got2 = lyric_args_get();
    CHECK(got2 == got);
    lyric_release(got2);
    CHECK(lyric_list_len(got) == 3); /* `got`'s own ref still holds the list alive */
    LyricString* s1_again = (LyricString*)(intptr_t)lyric_list_get(got, 1);
    CHECK(memcmp(LYRIC_STRING_DATA(s1_again), "alpha", 5) == 0);
    lyric_release(got);

    /* Re-setting argv invalidates the cache: the next call rebuilds
     * against the new argv instead of replaying the stale (now freed)
     * list — checked by content, since the allocator is free to reuse
     * `got`'s address for the rebuilt list. */
    char* argv2[] = {(char*)"prog2", (char*)"gamma"};
    lyric_args_set(2, argv2);
    LyricList* got3 = lyric_args_get();
    CHECK(lyric_list_len(got3) == 2);
    LyricString* s2 = (LyricString*)(intptr_t)lyric_list_get(got3, 1);
    CHECK(memcmp(LYRIC_STRING_DATA(s2), "gamma", 5) == 0);
    lyric_release(got3);

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
    CHECK(lyric_o_rdonly() == O_RDONLY);
    CHECK(lyric_mutex_size() > 0);

    CHECK(lyric_cstr_len("lyric") == 5);
    void* raw = lyric_malloc_raw(16);
    CHECK(raw != NULL);
    free(raw);
    char fd_tmpl[] = "/tmp/lyric_rt_fdwrap_XXXXXX";
    int tmp_fd = mkstemp(fd_tmpl);
    CHECK(tmp_fd >= 0);
    close(tmp_fd);
    int32_t fd = lyric_open_fd(fd_tmpl, lyric_o_wronly(), 0);
    CHECK(fd >= 0);
    CHECK(lyric_write_fd(fd, "abc", 3) == 3);
    close(fd);
    fd = lyric_open_fd(fd_tmpl, lyric_o_rdonly(), 0);
    CHECK(fd >= 0);
    char sink[4];
    CHECK(lyric_read_fd(fd, sink, 4) == 3);
    CHECK(memcmp(sink, "abc", 3) == 0);
    close(fd);
    unlink(fd_tmpl);

    char mutex_buf[128];
    CHECK(lyric_mutex_size() <= (int32_t)sizeof(mutex_buf));
    lyric_mutex_init(mutex_buf);
    lyric_mutex_lock(mutex_buf);
    lyric_mutex_lock(mutex_buf); /* reentrant: a protected member calls a sibling */
    lyric_mutex_unlock(mutex_buf);
    lyric_mutex_unlock(mutex_buf);
    lyric_mutex_destroy(mutex_buf);

    CHECK(lyric_epoch_millis() > 1000000000000LL); /* after 2001 */
    int64_t en = lyric_epoch_nanos();
    CHECK(en > 1000000000000000000LL); /* after 2001, in nanos */
    CHECK(en / 1000000 - lyric_epoch_millis() < 1000 &&
          lyric_epoch_millis() - en / 1000000 < 1000); /* same clock */
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

/* Argument/result for the cross-thread semaphore round-trip below. */
typedef struct {
    void* sem;
    volatile int posted; /* 1 once the waiter thread has woken and observed the post */
} sem_thread_ctx_t;

#ifndef __wasi__
static void* sem_wait_thread(void* arg) {
    sem_thread_ctx_t* ctx = (sem_thread_ctx_t*)arg;
    lyric_sem_wait(ctx->sem); /* blocks until test_semaphore's post below */
    ctx->posted = 1;
    return NULL;
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_semaphore(void) {
    CHECK(lyric_sem_size() > 0);

    char sem_buf[256];
    CHECK(lyric_sem_size() <= (int32_t)sizeof(sem_buf));

    /* Non-blocking case: an already-available permit is taken immediately. */
    lyric_sem_init(sem_buf, 1);
    lyric_sem_wait(sem_buf);
    lyric_sem_post(sem_buf);
    lyric_sem_post(sem_buf);
    lyric_sem_wait(sem_buf);
    lyric_sem_wait(sem_buf);
    lyric_sem_destroy(sem_buf);

    /* Blocking case: a real second thread blocks in lyric_sem_wait until
     * this thread posts — proves the condvar wakeup actually works, not
     * just the count bookkeeping (the shape of the request-queue /
     * per-request `done` signal _kernel_native/http_server.l needs, #6104). */
    char sem_buf2[256];
    CHECK(lyric_sem_size() <= (int32_t)sizeof(sem_buf2));
    lyric_sem_init(sem_buf2, 0);
    sem_thread_ctx_t ctx;
    ctx.sem = sem_buf2;
    ctx.posted = 0;
    pthread_t tid;
    CHECK(pthread_create(&tid, NULL, sem_wait_thread, &ctx) == 0);

    struct timespec ts = {0, 50 * 1000 * 1000}; /* 50ms: give the thread time to block */
    nanosleep(&ts, NULL);
    CHECK(ctx.posted == 0); /* still blocked: no post yet */

    lyric_sem_post(sem_buf2);
    CHECK(pthread_join(tid, NULL) == 0);
    CHECK(ctx.posted == 1);
    lyric_sem_destroy(sem_buf2);

    /* lyric_sem_trywait: never blocks. Reports 0 immediately against an
     * empty semaphore (the shape stopListener's abandoned-queue drain
     * relies on to never wait on a post nothing will ever send, #6796),
     * and correctly drains exactly as many credits as were posted,
     * leaving it empty again afterward. */
    char sem_buf3[256];
    CHECK(lyric_sem_size() <= (int32_t)sizeof(sem_buf3));
    lyric_sem_init(sem_buf3, 0);
    CHECK(lyric_sem_trywait(sem_buf3) == 0);
    CHECK(lyric_sem_trywait(sem_buf3) == 0); /* still empty: repeatable, not one-shot */
    lyric_sem_post(sem_buf3);
    lyric_sem_post(sem_buf3);
    CHECK(lyric_sem_trywait(sem_buf3) == 1);
    CHECK(lyric_sem_trywait(sem_buf3) == 1);
    CHECK(lyric_sem_trywait(sem_buf3) == 0); /* both credits already drained */
    lyric_sem_destroy(sem_buf3);
}
#endif /* !__wasi__ */

#ifndef __wasi__
/* Condition variables: a flag guarded by a mutex slot and a condition. */
typedef struct {
    void* mutex;
    void* cond;
    int flag;
    volatile int woke;
} cond_ctx_t;

static void* cond_waiter(void* arg) {
    cond_ctx_t* ctx = (cond_ctx_t*)arg;
    lyric_mutex_lock(ctx->mutex);
    while (!ctx->flag) {
        lyric_cond_wait(ctx->cond, ctx->mutex);
    }
    lyric_mutex_unlock(ctx->mutex);
    __atomic_add_fetch(&ctx->woke, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

static void sleep_ms(long ms) {
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000 * 1000};
    nanosleep(&ts, NULL);
}

static void test_condition_variable(void) {
    char mu[256];
    char cv[256];
    CHECK(lyric_cond_size() > 0 && lyric_cond_size() <= (int32_t)sizeof(cv));
    CHECK(lyric_mutex_size() <= (int32_t)sizeof(mu));
    lyric_mutex_init(mu);
    lyric_cond_init(cv);

    /* A timed wait with nobody to signal it times out after about its timeout
     * (not early, not far late) and holds the mutex again on return. */
    lyric_mutex_lock(mu);
    int64_t t0 = lyric_monotonic_nanos();
    CHECK(lyric_cond_timedwait(cv, mu, 60 * 1000000LL) == 0);
    int64_t waited = lyric_monotonic_nanos() - t0;
    CHECK(waited >= 55 * 1000000LL);
    CHECK(waited < 2000 * 1000000LL);
    /* A non-positive timeout does not block. */
    CHECK(lyric_cond_timedwait(cv, mu, 0) == 0);
    CHECK(lyric_cond_timedwait(cv, mu, -5) == 0);
    lyric_mutex_unlock(mu);

    /* broadcast wakes every waiter; none finishes before the flag is set. */
    cond_ctx_t ctx;
    ctx.mutex = mu;
    ctx.cond = cv;
    ctx.flag = 0;
    ctx.woke = 0;
    pthread_t tids[3];
    for (int i = 0; i < 3; i++) {
        CHECK(pthread_create(&tids[i], NULL, cond_waiter, &ctx) == 0);
    }
    sleep_ms(50);
    CHECK(__atomic_load_n(&ctx.woke, __ATOMIC_SEQ_CST) == 0);
    lyric_mutex_lock(mu);
    ctx.flag = 1;
    lyric_cond_broadcast(cv);
    lyric_mutex_unlock(mu);
    for (int i = 0; i < 3; i++) {
        CHECK(pthread_join(tids[i], NULL) == 0);
    }
    CHECK(ctx.woke == 3);

    /* signal wakes a timed waiter before its timeout, reporting 1. */
    lyric_mutex_lock(mu);
    ctx.flag = 0;
    lyric_mutex_unlock(mu);
    pthread_t sig;
    CHECK(pthread_create(&sig, NULL, cond_waiter, &ctx) == 0);
    sleep_ms(50);
    lyric_mutex_lock(mu);
    ctx.flag = 1;
    lyric_cond_signal(cv);
    lyric_mutex_unlock(mu);
    CHECK(pthread_join(sig, NULL) == 0);
    CHECK(ctx.woke == 4);

    lyric_cond_destroy(cv);
    lyric_mutex_destroy(mu);
}

/* The mutex slot is a reentrant monitor: a protected type's `when:` barrier
 * waits on it with lyric_mutex_wait, releasing every nested level. */
typedef struct {
    void* mon;
    int state;
    volatile int released;
} monitor_ctx_t;

static void* monitor_waiter(void* arg) {
    monitor_ctx_t* ctx = (monitor_ctx_t*)arg;
    lyric_mutex_lock(ctx->mon);
    lyric_mutex_lock(ctx->mon); /* a member calling a sibling: depth 2 */
    while (ctx->state == 0) {
        lyric_mutex_wait(ctx->mon);
    }
    /* Back at depth 2: two unlocks release it. */
    lyric_mutex_unlock(ctx->mon);
    lyric_mutex_unlock(ctx->mon);
    __atomic_store_n(&ctx->released, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

static void test_monitor(void) {
    char mon[256];
    CHECK(lyric_mutex_size() <= (int32_t)sizeof(mon));
    lyric_mutex_init(mon);

    /* Reentrant on one thread. */
    lyric_mutex_lock(mon);
    lyric_mutex_lock(mon);
    lyric_mutex_lock(mon);
    lyric_mutex_unlock(mon);
    lyric_mutex_unlock(mon);
    lyric_mutex_unlock(mon);

    /* A waiter holding two levels waits; the notifier can take the lock
     * (every level was released), change state and wake it; the waiter
     * returns holding both levels again. */
    monitor_ctx_t ctx;
    ctx.mon = mon;
    ctx.state = 0;
    ctx.released = 0;
    pthread_t tid;
    CHECK(pthread_create(&tid, NULL, monitor_waiter, &ctx) == 0);
    sleep_ms(80);
    CHECK(__atomic_load_n(&ctx.released, __ATOMIC_SEQ_CST) == 0);
    lyric_mutex_lock(mon); /* would block forever if the waiter kept a level */
    ctx.state = 1;
    lyric_mutex_notify_all(mon);
    lyric_mutex_unlock(mon);
    CHECK(pthread_join(tid, NULL) == 0);
    CHECK(ctx.released == 1);

    /* The lock is free again for a thread that never held it. */
    lyric_mutex_lock(mon);
    lyric_mutex_unlock(mon);
    lyric_mutex_destroy(mon);
}

/* The global condition shares the global lock: a waiter holding it releases
 * it while blocked, so another thread can take it, change state and wake it. */
static volatile int global_flag = 0;
static volatile int global_timed_result = -1;

static void* global_waiter(void* arg) {
    (void)arg;
    lyric_global_lock();
    while (!global_flag) {
        lyric_global_cond_wait();
    }
    lyric_global_unlock();
    return NULL;
}

static void* global_timed_waiter(void* arg) {
    (void)arg;
    lyric_global_lock();
    int r = 0;
    while (!global_flag && r == 0) {
        r = lyric_global_cond_timedwait(5000LL * 1000000LL);
    }
    global_timed_result = r;
    lyric_global_unlock();
    return NULL;
}

static void test_global_condition(void) {
    /* Timeout path: nothing signals, the wait returns 0 near its timeout and
     * the global lock is held again afterwards. */
    lyric_global_lock();
    int64_t t0 = lyric_monotonic_nanos();
    CHECK(lyric_global_cond_timedwait(40 * 1000000LL) == 0);
    CHECK(lyric_monotonic_nanos() - t0 >= 35 * 1000000LL);
    lyric_global_unlock();

    /* Wake path: untimed and timed waiters both leave once the flag is set
     * and broadcast, long before the timed one's 5 s timeout. */
    global_flag = 0;
    pthread_t a;
    pthread_t b;
    CHECK(pthread_create(&a, NULL, global_waiter, NULL) == 0);
    CHECK(pthread_create(&b, NULL, global_timed_waiter, NULL) == 0);
    sleep_ms(50);
    int64_t t1 = lyric_monotonic_nanos();
    lyric_global_lock();
    global_flag = 1;
    lyric_global_cond_broadcast();
    lyric_global_unlock();
    CHECK(pthread_join(a, NULL) == 0);
    CHECK(pthread_join(b, NULL) == 0);
    CHECK(lyric_monotonic_nanos() - t1 < 2000 * 1000000LL);
    CHECK(global_timed_result == 1);
}
#endif /* !__wasi__ */

static void test_uuid_v4(void) {
    /* Canonical lowercase hyphenated form with the RFC 4122 version-4
     * and variant-10 marker positions, distinct across calls. */
    LyricString* a = lyric_uuid_v4();
    LyricString* b = lyric_uuid_v4();
    CHECK(lyric_string_len(a) == 36);
    CHECK(lyric_string_len(b) == 36);
    const uint8_t* p = LYRIC_STRING_DATA(a);
    for (int i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            CHECK(p[i] == '-');
        } else {
            CHECK((p[i] >= '0' && p[i] <= '9') || (p[i] >= 'a' && p[i] <= 'f'));
        }
    }
    CHECK(p[14] == '4');
    CHECK(p[19] == '8' || p[19] == '9' || p[19] == 'a' || p[19] == 'b');
    CHECK(memcmp(LYRIC_STRING_DATA(a), LYRIC_STRING_DATA(b), 36) != 0);
    lyric_release(a);
    lyric_release(b);
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

static void test_file_mtime(void) {
    char dir_tmpl[] = "/tmp/lyric_rt_test_mtime_XXXXXX";
    char* dir = mkdtemp(dir_tmpl);
    CHECK(dir != NULL);

    char path[512];
    snprintf(path, sizeof path, "%s/a.txt", dir);
    LyricString* content = lyric_string_from_literal((const uint8_t*)"x", 1);
    CHECK(lyric_file_write_all(path, content, 0) == 0);
    lyric_release(content);

    /* Missing path fails cleanly, *out untouched. */
    char missing[512];
    snprintf(missing, sizeof missing, "%s/missing.txt", dir);
    int64_t untouched = 12345;
    CHECK(lyric_file_mtime_epoch_nanos_ok(missing, &untouched) == -1);
    CHECK(untouched == 12345);

    /* utimes(2) pins an exact, known mtime (avoids a sleep-based flaky
     * test): 2024-01-15T10:30:45.500000Z, i.e. 1705314645 seconds and
     * 500000 microseconds past the Unix epoch. */
    struct timeval times[2];
    times[0].tv_sec = 1705314645;
    times[0].tv_usec = 500000;
    times[1].tv_sec = 1705314645;
    times[1].tv_usec = 500000;
    CHECK(utimes(path, times) == 0);

    int64_t nanos = 0;
    CHECK(lyric_file_mtime_epoch_nanos_ok(path, &nanos) == 0);
    CHECK(nanos == 1705314645500000000LL);

    /* A strictly later mtime converts to a strictly larger nanos value
     * (the ordering fileStatIsNewer's `>` comparison relies on). */
    char path2[512];
    snprintf(path2, sizeof path2, "%s/b.txt", dir);
    LyricString* content2 = lyric_string_from_literal((const uint8_t*)"y", 1);
    CHECK(lyric_file_write_all(path2, content2, 0) == 0);
    lyric_release(content2);
    times[0].tv_sec = 1705314646;
    times[1].tv_sec = 1705314646;
    CHECK(utimes(path2, times) == 0);
    int64_t nanos2 = 0;
    CHECK(lyric_file_mtime_epoch_nanos_ok(path2, &nanos2) == 0);
    CHECK(nanos2 > nanos);

#ifndef __wasi__
    /* A pre-1970 mtime round-trips too (negative epoch nanos, within
     * Instant's own supported 1677..2262 window).  WASI file timestamps are
     * unsigned nanoseconds, so a pre-1970 mtime cannot be set there. */
    times[0].tv_sec = -3600;
    times[0].tv_usec = 0;
    times[1].tv_sec = -3600;
    times[1].tv_usec = 0;
    CHECK(utimes(path, times) == 0);
    int64_t negNanos = 0;
    CHECK(lyric_file_mtime_epoch_nanos_ok(path, &negNanos) == 0);
    CHECK(negNanos == -3600000000000LL);
#endif

    CHECK(lyric_file_delete(path) == 0);
    CHECK(lyric_file_delete(path2) == 0);
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

    /* create_all: nested parents, idempotent, trailing slash, and a
     * regular file in the way. */
    char deep[512], mid[512], top[512];
    snprintf(top, sizeof top, "%s/a", dir);
    snprintf(mid, sizeof mid, "%s/a/b", dir);
    snprintf(deep, sizeof deep, "%s/a/b/c/", dir);
    CHECK(lyric_dir_create_all(deep) == 0);
    CHECK(lyric_dir_exists(deep));
    CHECK(lyric_dir_create_all(deep) == 0);
    CHECK(lyric_dir_create_all(sub) == 0);
    CHECK(lyric_dir_create_all("") == -1);
    char blocked[512];
    snprintf(blocked, sizeof blocked, "%s/one.txt/x", dir);
    CHECK(lyric_dir_create_all(blocked) == -1);
    CHECK(lyric_dir_create_all(f1) == -1);
    CHECK(lyric_dir_remove(deep) == 0);
    CHECK(lyric_dir_remove(mid) == 0);
    CHECK(lyric_dir_remove(top) == 0);

    /* Removal: non-empty dir fails, empty dir succeeds. */
    CHECK(lyric_dir_remove(dir) == -1); /* not empty */
    CHECK(lyric_dir_remove(sub) == 0);
    CHECK(!lyric_dir_exists(sub));

    unlink(f1);
    unlink(f2);
    CHECK(lyric_dir_remove(dir) == 0);
    CHECK(!lyric_dir_exists(dir));
}

#ifndef __wasi__
static void test_console_write_line(void) {
    int fds[2];
    CHECK(pipe(fds) == 0);
    LyricString* s = lyric_string_from_literal((const uint8_t*)"hello", 5);
    LyricString* empty = lyric_string_from_literal((const uint8_t*)"", 0);
    lyric_console_write_line(fds[1], s);
    lyric_console_write_line(fds[1], empty);
    lyric_console_write_line(fds[1], NULL);
    close(fds[1]);
    char buf[32];
    ssize_t total = 0;
    ssize_t n;
    while ((n = read(fds[0], buf + total, sizeof buf - (size_t)total)) > 0) total += n;
    close(fds[0]);
    CHECK(total == 8);
    CHECK(memcmp(buf, "hello\n\n\n", 8) == 0);
    lyric_release(s);
    lyric_release(empty);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_console_write_bytes(void) {
    int fds[2];
    CHECK(pipe(fds) == 0);
    /* UTF-8 bytes for "a\xC3\xA9" (a, U+00E9) so this exercises non-ASCII
     * bytes, not just a plain string round-trip (#7510). */
    LyricList* bytes = lyric_list_new(3);
    lyric_list_push(bytes, 'a');
    lyric_list_push(bytes, 0xC3);
    lyric_list_push(bytes, 0xA9);
    lyric_console_write_bytes(fds[1], bytes);
    lyric_console_write_bytes(fds[1], NULL);
    LyricList* empty = lyric_list_new(0);
    lyric_console_write_bytes(fds[1], empty);
    close(fds[1]);
    unsigned char buf[16];
    ssize_t total = 0;
    ssize_t n;
    while ((n = read(fds[0], buf + total, sizeof buf - (size_t)total)) > 0) total += n;
    close(fds[0]);
    CHECK(total == 3);
    CHECK(memcmp(buf, "a\xC3\xA9", 3) == 0);
    lyric_release(bytes);
    lyric_release(empty);
}
#endif /* !__wasi__ */

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

#ifndef __wasi__
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
    CHECK(lyric_process_run("/bin/echo", args, NULL, -1, &exit_code, &out, &err, NULL) == 0);
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
    CHECK(lyric_process_run("/bin/ls", bad_args, NULL, -1, &exit_code2, &out2, &err2, NULL) == 0);
    CHECK(exit_code2 != 0);
    CHECK(lyric_string_len(err2) > 0);
    lyric_release(out2);
    lyric_release(err2);
    lyric_release(bad_args);

    /* No args: argv is just argv[0]. */
    int32_t exit_code3 = -99;
    LyricString* out3 = NULL;
    LyricString* err3 = NULL;
    CHECK(lyric_process_run("/bin/echo", NULL, NULL, -1, &exit_code3, &out3, &err3, NULL) == 0);
    CHECK(exit_code3 == 0);
    CHECK(lyric_string_len(out3) == 1); /* just the trailing newline */
    lyric_release(out3);
    lyric_release(err3);

    /* Spawn failure (path lookup handled by execvp inside the child, so
     * a missing executable is exit code 127, not a spawn failure): */
    int32_t exit_code4 = -99;
    LyricString* out4 = NULL;
    LyricString* err4 = NULL;
    CHECK(lyric_process_run("/nonexistent-lyric-rt-test-exe", NULL, NULL, -1, &exit_code4, &out4, &err4, NULL) ==
          0);
    CHECK(exit_code4 == 127);
    lyric_release(out4);
    lyric_release(err4);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_run_inherited(void) {
    LyricList* args = lyric_list_new(2);
    LyricString* a1 = lyric_string_from_literal((const uint8_t*)"-c", 2);
    LyricString* a2 = lyric_string_from_literal((const uint8_t*)"exit 7", 6);
    lyric_list_push(args, (int64_t)(intptr_t)a1);
    lyric_list_push(args, (int64_t)(intptr_t)a2);
    lyric_release(a1);
    lyric_release(a2);
    int32_t code = -99;
    CHECK(lyric_process_run_inherited("/bin/sh", args, &code) == 0);
    CHECK(code == 7);
    lyric_release(args);

    /* No args, zero exit. */
    int32_t code2 = -99;
    CHECK(lyric_process_run_inherited("/bin/true", NULL, &code2) == 0);
    CHECK(code2 == 0);

    /* A missing executable is a spawn failure, and leaves the out-param
     * untouched. */
    int32_t code3 = -99;
    CHECK(lyric_process_run_inherited("/nonexistent-lyric-rt-test-exe", NULL, &code3) == -1);
    CHECK(code3 == -99);
    CHECK(lyric_process_last_spawn_errno() == ENOENT);
    LyricString* msg = lyric_process_errno_message(ENOENT);
    CHECK(lyric_string_len(msg) > 0);
    lyric_release(msg);

    /* A signal-terminated child reports 128 + signal number. */
    LyricList* kargs = lyric_list_new(2);
    LyricString* k1 = lyric_string_from_literal((const uint8_t*)"-c", 2);
    LyricString* k2 = lyric_string_from_literal((const uint8_t*)"kill -9 $$", 10);
    lyric_list_push(kargs, (int64_t)(intptr_t)k1);
    lyric_list_push(kargs, (int64_t)(intptr_t)k2);
    lyric_release(k1);
    lyric_release(k2);
    int32_t code4 = -99;
    CHECK(lyric_process_run_inherited("/bin/sh", kargs, &code4) == 0);
    CHECK(code4 == 128 + 9);
    lyric_release(kargs);
}
#endif /* !__wasi__ */

static LyricString* str_lit(const char* c) {
    return lyric_string_from_literal((const uint8_t*)c, (int64_t)strlen(c));
}

static int str_eq(LyricString* s, const char* c) {
    int64_t n = (int64_t)strlen(c);
    return lyric_string_len(s) == n && (n == 0 || memcmp(LYRIC_STRING_DATA(s), c, (size_t)n) == 0);
}

static void check_replace(const char* s, const char* old, const char* rep, const char* want) {
    LyricString* a = str_lit(s);
    LyricString* b = str_lit(old);
    LyricString* c = str_lit(rep);
    LyricString* got = lyric_string_replace(a, b, c);
    CHECK(str_eq(got, want));
    lyric_release(got);
    lyric_release(a);
    lyric_release(b);
    lyric_release(c);
}

static void test_string_replace(void) {
    check_replace("a,b,,c", ",", ";", "a;b;;c");
    check_replace("hello", "l", "", "heo");          /* removal */
    check_replace("aaaa", "aa", "b", "bb");           /* non-overlapping */
    check_replace("aaa", "aa", "b", "ba");            /* left to right */
    check_replace("abc", "abc", "xyzxyz", "xyzxyz");  /* whole string, growth */
    check_replace("abc", "zz", "y", "abc");           /* no match */
    check_replace("", "a", "b", "");                  /* empty input */
    check_replace("x::y", "::", "\\\\", "x\\\\y");    /* backslashes */
    check_replace("caf\xc3\xa9 caf\xc3\xa9", "\xc3\xa9", "e", "cafe cafe"); /* multibyte */
}

#ifndef __wasi__
static void test_process_closed_stdio(void) {
    /* Regression: with fd 1/2 closed in the caller, pipe() hands the child
     * those very numbers.  The original wiring dup2'ed in place (a no-op
     * when source == target) and then unconditionally closed the source,
     * destroying the just-installed descriptor; spawn_capture now
     * F_DUPFD-lifts every source above 2 before dup2'ing onto 0/1/2, so
     * no source can alias its target.  Run a capture with stdout/stderr
     * closed and verify the output still comes back intact.  Assertions
     * in the fork are reported through the exit status — its stderr is
     * closed by construction. */
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
        /* With 1/2 closed, pipe() returns {1,2} for out_pipe — the
         * aliasing shape that broke the original wiring.  The command
         * must write to BOTH streams: with the historical bug, stderr
         * writes hit a closed fd and the err capture came back empty. */
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
        if (lyric_process_run("/bin/sh", args, NULL, -1, &code, &out, &err, NULL) != 0) _exit(1);
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
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_closed_stdin_stdout(void) {
    /* With fds 0 and 1 closed, pipe() returns {0,1} for out_pipe, so
     * out_pipe[1] IS STDOUT_FILENO.  The pipes are created CLOEXEC, and a
     * self-aliased dup2 would leave that flag set (exec would close the
     * just-wired stdout); spawn_capture's F_DUPFD lift above 2 guarantees
     * a real dup2 happens, which clears CLOEXEC on the target, so the
     * capture must come back non-empty. */
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
        if (lyric_process_run("/bin/echo", args, NULL, -1, &code, &out, &err, NULL) != 0) _exit(1);
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
#endif /* !__wasi__ */

/* ── Nonblocking process op (the async process leaf, D-N-023) ───────── */
#ifndef __wasi__
static void test_process_op_basic(void) {
    /* echo through the pump loop: start, pump until done, read results. */
    LyricList* args = lyric_list_new(1);
    LyricString* a = lyric_string_from_literal((const uint8_t*)"pump", 4);
    lyric_list_push(args, (int64_t)(intptr_t)a);
    lyric_release(a);
    void* op = lyric_process_start("/bin/echo", args, NULL);
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
#endif /* !__wasi__ */

#ifndef __wasi__
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
    void* op = lyric_process_start("/bin/sh", argv, NULL);
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
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_op_kill_after_exit(void) {
    /* kill on an op whose child already finished must NOT report a
     * kill (#5107: the deadline can fire inside the window between the
     * child exiting and the WNOHANG reap seeing it — a false timeout).
     * A done op returns 0; the real exit status stays intact. */
    LyricList* args = lyric_list_new(1);
    LyricString* a = lyric_string_from_literal((const uint8_t*)"beat-the-kill", 13);
    lyric_list_push(args, (int64_t)(intptr_t)a);
    lyric_release(a);
    void* op = lyric_process_start("/bin/echo", args, NULL);
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
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_op_exec_failure(void) {
    /* execvp failure inside the child: exit 127, empty output, no spawn
     * failure (matching lyric_process_run and shell convention). */
    void* op = lyric_process_start("/nonexistent-lyric-op-binary", NULL, NULL);
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
    /* The child _exits without writing anything: execvp itself is
     * silent, so stderr must be empty too (#5116). */
    LyricString* errs = lyric_process_stderr(op);
    CHECK(lyric_string_len(errs) == 0);
    lyric_release(errs);
    lyric_process_free(op);
}
#endif /* !__wasi__ */

/* -- stdin + sync timeout (#4752 closure) --------------------------- */
#ifndef __wasi__
static void test_process_stdin_roundtrip(void) {
    /* cat echoes stdin back on stdout through the sync runner. */
    LyricString* content = lyric_string_from_literal((const uint8_t*)"in-out", 6);
    int32_t code = -1;
    LyricString* out = NULL;
    LyricString* err = NULL;
    int32_t timed_out = -1;
    CHECK(lyric_process_run("/bin/cat", NULL, content, -1, &code, &out, &err, &timed_out) == 0);
    CHECK(code == 0);
    CHECK(timed_out == 0);
    CHECK(lyric_string_len(out) == 6);
    CHECK(memcmp(LYRIC_STRING_DATA(out), "in-out", 6) == 0);
    lyric_release(content);
    lyric_release(out);
    lyric_release(err);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_stdin_large_no_deadlock(void) {
    /* 256 KiB through cat: far beyond the pipe buffer in BOTH
     * directions, so this deadlocks unless stdin writes interleave
     * with stdout reads in the poll loop. */
    int64_t big = 256 * 1024;
    uint8_t* data = (uint8_t*)malloc((size_t)big);
    CHECK(data != NULL);
    for (int64_t i = 0; i < big; i++) data[i] = (uint8_t)('a' + (i % 26));
    LyricString* content = lyric_string_from_literal(data, big);
    int32_t code = -1;
    LyricString* out = NULL;
    LyricString* err = NULL;
    int32_t timed_out = -1;
    CHECK(lyric_process_run("/bin/cat", NULL, content, 30000, &code, &out, &err, &timed_out) == 0);
    CHECK(code == 0);
    CHECK(timed_out == 0);
    CHECK(lyric_string_len(out) == big);
    CHECK(memcmp(LYRIC_STRING_DATA(out), data, (size_t)big) == 0);
    free(data);
    lyric_release(content);
    lyric_release(out);
    lyric_release(err);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_stdin_child_ignores(void) {
    /* A child that exits without reading its (large) stdin: the EPIPE
     * path must silently drop the rest — no SIGPIPE death, real exit
     * code preserved. */
    int64_t big = 256 * 1024;
    uint8_t* data = (uint8_t*)malloc((size_t)big);
    CHECK(data != NULL);
    memset(data, 'x', (size_t)big);
    LyricString* content = lyric_string_from_literal(data, big);
    LyricList* argv = lyric_list_new(1);
    LyricString* dash_c = lyric_string_from_literal((const uint8_t*)"-c", 2);
    lyric_list_push(argv, (int64_t)(intptr_t)dash_c);
    lyric_release(dash_c);
    LyricString* script = lyric_string_from_literal((const uint8_t*)"exit 3", 6);
    lyric_list_push(argv, (int64_t)(intptr_t)script);
    lyric_release(script);
    int32_t code = -1;
    LyricString* out = NULL;
    LyricString* err = NULL;
    int32_t timed_out = -1;
    CHECK(lyric_process_run("/bin/sh", argv, content, 30000, &code, &out, &err, &timed_out) == 0);
    CHECK(code == 3);
    CHECK(timed_out == 0);
    free(data);
    lyric_release(argv);
    lyric_release(content);
    lyric_release(out);
    lyric_release(err);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_sync_timeout(void) {
    /* The sync runner kills a sleeping child at the deadline,
     * preserving pre-timeout output (mirrors the async op contract). */
    LyricList* argv = lyric_list_new(1);
    LyricString* dash_c = lyric_string_from_literal((const uint8_t*)"-c", 2);
    lyric_list_push(argv, (int64_t)(intptr_t)dash_c);
    lyric_release(dash_c);
    LyricString* script = lyric_string_from_literal((const uint8_t*)"echo pre; sleep 30", 18);
    lyric_list_push(argv, (int64_t)(intptr_t)script);
    lyric_release(script);
    int32_t code = -1;
    LyricString* out = NULL;
    LyricString* err = NULL;
    int32_t timed_out = -1;
    CHECK(lyric_process_run("/bin/sh", argv, NULL, 300, &code, &out, &err, &timed_out) == 0);
    CHECK(timed_out == 1);
    CHECK(code == 128 + SIGKILL);
    CHECK(lyric_string_len(out) == 4);
    CHECK(memcmp(LYRIC_STRING_DATA(out), "pre\n", 4) == 0);
    lyric_release(argv);
    lyric_release(out);
    lyric_release(err);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_sync_timeout_pending_stdin(void) {
    /* Deadline kill with a stdin feed still in flight (#5175): the
     * child never reads, so the pipe buffer fills and the parent is
     * left holding most of 256 KiB when the deadline hits.  The kill
     * path must close the write end and the post-kill drain must still
     * terminate promptly instead of waiting on the undeliverable rest. */
    int64_t big = 256 * 1024;
    uint8_t* data = (uint8_t*)malloc((size_t)big);
    CHECK(data != NULL);
    memset(data, 'y', (size_t)big);
    LyricString* content = lyric_string_from_literal(data, big);
    free(data);
    LyricList* argv = lyric_list_new(1);
    LyricString* dash_c = lyric_string_from_literal((const uint8_t*)"-c", 2);
    lyric_list_push(argv, (int64_t)(intptr_t)dash_c);
    lyric_release(dash_c);
    LyricString* script = lyric_string_from_literal((const uint8_t*)"sleep 30", 8);
    lyric_list_push(argv, (int64_t)(intptr_t)script);
    lyric_release(script);
    int32_t code = -1;
    LyricString* out = NULL;
    LyricString* err = NULL;
    int32_t timed_out = -1;
    int64_t t0 = lyric_monotonic_nanos();
    CHECK(lyric_process_run("/bin/sh", argv, content, 300, &code, &out, &err, &timed_out) == 0);
    int64_t elapsed_ms = (lyric_monotonic_nanos() - t0) / 1000000;
    CHECK(timed_out == 1);
    CHECK(code == 128 + SIGKILL);
    CHECK(lyric_string_len(out) == 0);
    /* Generous bound: the point is "not 30 s", not scheduler timing. */
    CHECK(elapsed_ms < 10000);
    lyric_release(content);
    lyric_release(argv);
    lyric_release(out);
    lyric_release(err);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_sync_timeout_grandchild_writer(void) {
    /* Group kill (D-N-025): the background writer is in the child's
     * process group, so the deadline kill takes it too — the drain
     * then ends on pipe EOF well inside the 2 s budget (#5176), which
     * the elapsed bound below discriminates: the pre-group-kill
     * runtime survived the writer and only the budget ended the
     * drain, at >= 2 s. */
    LyricList* argv = lyric_list_new(1);
    LyricString* dash_c = lyric_string_from_literal((const uint8_t*)"-c", 2);
    lyric_list_push(argv, (int64_t)(intptr_t)dash_c);
    lyric_release(dash_c);
    const char* cmd = "(while :; do echo g; sleep 0.05; done) & sleep 30";
    LyricString* script = lyric_string_from_literal((const uint8_t*)cmd, (int64_t)strlen(cmd));
    lyric_list_push(argv, (int64_t)(intptr_t)script);
    lyric_release(script);
    int32_t code = -1;
    LyricString* out = NULL;
    LyricString* err = NULL;
    int32_t timed_out = -1;
    int64_t t0 = lyric_monotonic_nanos();
    CHECK(lyric_process_run("/bin/sh", argv, NULL, 300, &code, &out, &err, &timed_out) == 0);
    int64_t elapsed_ms = (lyric_monotonic_nanos() - t0) / 1000000;
    CHECK(timed_out == 1);
    CHECK(code == 128 + SIGKILL);
    /* ~300 ms deadline + EOF-based drain exit (~500 ms total).  A
     * regression to child-only kills cannot finish before ~2.3 s by
     * construction (deadline + the full 2 s drain budget), so a 2 s
     * bound still discriminates while leaving ~1.5 s of headroom for
     * loaded CI runners (#5187). */
    CHECK(elapsed_ms < 2000);
    lyric_release(argv);
    lyric_release(out);
    lyric_release(err);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_sync_timeout_setsid_escapee(void) {
    /* The drain-budget backstop (#5176) still matters for a
     * descendant that leaves the child's process group: a setsid'd
     * writer survives the group kill, holds the stdout write end, and
     * keeps producing — the 2 s budget must end the drain (it dies of
     * SIGPIPE at the force-close).  setsid(1) is util-linux; on
     * platforms without it (macOS) this scenario cannot be built from
     * a shell one-liner, so the test self-skips.
     *
     * The scenario is racy to CONSTRUCT on a loaded runner: if the
     * setsid'd writer hasn't started by the time the 300 ms timeout
     * kills the process group, nothing holds the pipe, the drain sees
     * immediate EOF, and the sub-budget elapsed time is CORRECT
     * behavior for what actually ran — not a drain-budget failure.
     * The escapee is the only writer, so a non-empty stdout is the
     * exact witness that it was alive past spawn; assert the budget
     * bounds only on a run where the scenario materialized, retrying
     * a few times so coverage is near-certain (observed flaking in CI
     * on PR #6420). */
    if (access("/usr/bin/setsid", X_OK) != 0 && access("/bin/setsid", X_OK) != 0) {
        return;
    }
    const char* cmd = "setsid sh -c 'while :; do echo g; sleep 0.05; done' & sleep 30";
    for (int attempt = 0; attempt < 3; attempt++) {
        LyricList* argv = lyric_list_new(1);
        LyricString* dash_c = lyric_string_from_literal((const uint8_t*)"-c", 2);
        lyric_list_push(argv, (int64_t)(intptr_t)dash_c);
        lyric_release(dash_c);
        LyricString* script = lyric_string_from_literal((const uint8_t*)cmd, (int64_t)strlen(cmd));
        lyric_list_push(argv, (int64_t)(intptr_t)script);
        lyric_release(script);
        int32_t code = -1;
        LyricString* out = NULL;
        LyricString* err = NULL;
        int32_t timed_out = -1;
        int64_t t0 = lyric_monotonic_nanos();
        CHECK(lyric_process_run("/bin/sh", argv, NULL, 300, &code, &out, &err, &timed_out) == 0);
        int64_t elapsed_ms = (lyric_monotonic_nanos() - t0) / 1000000;
        CHECK(timed_out == 1);
        CHECK(code == 128 + SIGKILL);
        int escapee_ran = out != NULL && lyric_string_len(out) > 0;
        lyric_release(argv);
        lyric_release(out);
        lyric_release(err);
        /* Non-empty stdout only proves the escapee wrote *something*
         * before the group kill landed — not that it survived past it.
         * setsid() has a brief window before it takes effect; a write
         * emitted in that window can land in the pipe even though the
         * writer dies with the rest of the group at the ~300 ms
         * deadline, finishing the whole run in a few hundred ms. That
         * is the same "scenario didn't materialize" case as the
         * empty-output retry below, just with a stray byte already
         * captured, so require the elapsed bound too before treating
         * this as the drain-budget scenario (observed CI flake:
         * escapee_ran true with elapsed_ms well under 1500 — the
         * group-kill race, not a drain-budget regression). */
        if (escapee_ran && elapsed_ms >= 1500) {
            /* The escapee kept the pipe alive past the kill, so the
             * drain ran to its budget: at least ~2 s elapsed, but
             * nowhere near the 30 s the writer would otherwise pin
             * the loop for. */
            CHECK(elapsed_ms < 10000);
            return;
        }
    }
    fprintf(stderr,
            "note: setsid escapee never started within the timeout window "
            "in 3 attempts (heavily loaded runner?); drain-budget bounds "
            "not exercised this run\n");
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_op_stdin(void) {
    /* The async op pumps stdin nonblockingly: cat round-trips 256 KiB
     * through start/pump alone. */
    int64_t big = 256 * 1024;
    uint8_t* data = (uint8_t*)malloc((size_t)big);
    CHECK(data != NULL);
    for (int64_t i = 0; i < big; i++) data[i] = (uint8_t)('A' + (i % 26));
    LyricString* content = lyric_string_from_literal(data, big);
    void* op = lyric_process_start("/bin/cat", NULL, content);
    lyric_release(content); /* the op holds its own copy */
    CHECK(!lyric_process_spawn_failed(op));
    int spins = 0;
    while (!lyric_process_pump(op) && spins < 10000) {
        struct timespec ts = {0, 1000000};
        nanosleep(&ts, NULL);
        spins++;
    }
    CHECK(lyric_process_pump(op) == 1);
    CHECK(lyric_process_exit_code(op) == 0);
    LyricString* out = lyric_process_stdout(op);
    CHECK(lyric_string_len(out) == big);
    CHECK(memcmp(LYRIC_STRING_DATA(out), data, (size_t)big) == 0);
    free(data);
    lyric_release(out);
    lyric_process_free(op);
}
#endif /* !__wasi__ */

/* ── Long-lived piped child stdio (issue #6142) ──────────────────────── */

#ifndef __wasi__
static LyricString* mk_str(const char* s) {
    return lyric_string_from_literal((const uint8_t*)s, (int64_t)strlen(s));
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_line_roundtrip(void) {
    /* `cat` echoes each written line back on stdout — the direct
     * line-oriented round trip the MCP stdio transport needs. */
    void* p = lyric_process_piped_spawn("/bin/cat", NULL);
    CHECK(p != NULL);
    CHECK(lyric_process_piped_is_alive(p) == 1);

    LyricString* l1 = mk_str("hello");
    CHECK(lyric_process_piped_write_line(p, l1) == 0);
    lyric_release(l1);
    LyricString* got1 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got1) == 1);
    CHECK(got1 != NULL);
    CHECK(lyric_string_len(got1) == 5);
    CHECK(memcmp(LYRIC_STRING_DATA(got1), "hello", 5) == 0);
    lyric_release(got1);

    LyricString* l2 = mk_str("world again");
    CHECK(lyric_process_piped_write_line(p, l2) == 0);
    lyric_release(l2);
    LyricString* got2 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got2) == 1);
    CHECK(lyric_string_len(got2) == 11);
    CHECK(memcmp(LYRIC_STRING_DATA(got2), "world again", 11) == 0);
    lyric_release(got2);

    CHECK(lyric_process_piped_close_stdin(p) == 0);
    LyricString* l3 = mk_str("after close");
    CHECK(lyric_process_piped_write_line(p, l3) == -2);
    lyric_release(l3);
    /* cat sees EOF on stdin, writes nothing more, and exits. */
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    CHECK(lyric_process_piped_exit_code(p) == 0);
    CHECK(lyric_process_piped_is_alive(p) == 0);
    /* No more lines were ever written after l2 — read_line must report
     * end-of-stream, not hang. */
    LyricString* got3 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got3) == 0);
    lyric_process_piped_close(p);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_final_line_without_newline(void) {
    /* `printf` (no trailing newline) — the final-partial-line-at-EOF
     * case: read_line must still return it once, then report
     * end-of-stream on every call after. */
    LyricList* args = lyric_list_new(2);
    LyricString* fmt = mk_str("%s");
    LyricString* body = mk_str("trailing");
    lyric_list_push(args, (int64_t)(intptr_t)fmt);
    lyric_list_push(args, (int64_t)(intptr_t)body);
    lyric_release(fmt);
    lyric_release(body);

    void* p = lyric_process_piped_spawn("/usr/bin/printf", args);
    lyric_release(args);
    CHECK(p != NULL);

    LyricString* got = NULL;
    CHECK(lyric_process_piped_read_line(p, &got) == 1);
    CHECK(lyric_string_len(got) == 8);
    CHECK(memcmp(LYRIC_STRING_DATA(got), "trailing", 8) == 0);
    lyric_release(got);

    LyricString* got2 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got2) == 0);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    CHECK(lyric_process_piped_exit_code(p) == 0);
    lyric_process_piped_close(p);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_read_line_within(void) {
    /* Issue #7451: a silent child times out (2) instead of blocking; a
     * line that arrives after the deadline is returned by the next read. */
    void* p = lyric_process_piped_spawn("/bin/cat", NULL);
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
    CHECK(lyric_string_len(got) == 4);
    CHECK(memcmp(LYRIC_STRING_DATA(got), "late", 4) == 0);
    lyric_release(got);

    CHECK(lyric_process_piped_close_stdin(p) == 0);
    LyricString* eof = NULL;
    CHECK(lyric_process_piped_read_line_within(p, &eof, 5000) == 0);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    lyric_process_piped_close(p);

    /* A line split across the deadline: the half read before the timeout
     * stays buffered and is joined with the rest by the next read. */
    LyricList* args = lyric_list_new(2);
    LyricString* flag = mk_str("-c");
    LyricString* script = mk_str("printf abc; sleep 1; printf 'def\\n'");
    lyric_list_push(args, (int64_t)(intptr_t)flag);
    lyric_list_push(args, (int64_t)(intptr_t)script);
    lyric_release(flag);
    lyric_release(script);
    void* q = lyric_process_piped_spawn("/bin/sh", args);
    lyric_release(args);
    CHECK(q != NULL);
    LyricString* partial = NULL;
    CHECK(lyric_process_piped_read_line_within(q, &partial, 300) == 2);
    LyricString* whole = NULL;
    CHECK(lyric_process_piped_read_line_within(q, &whole, 10000) == 1);
    CHECK(lyric_string_len(whole) == 6);
    CHECK(memcmp(LYRIC_STRING_DATA(whole), "abcdef", 6) == 0);
    lyric_release(whole);
    CHECK(lyric_process_piped_wait_exit(q, 5000) == 1);
    lyric_process_piped_close(q);

    /* #7523: a zero budget still returns a line that is already sitting in
     * the pipe, and a zero budget with nothing written still times out. */
    void* r = lyric_process_piped_spawn("/bin/cat", NULL);
    CHECK(r != NULL);
    LyricString* ready = mk_str("ready");
    CHECK(lyric_process_piped_write_line(r, ready) == 0);
    lyric_release(ready);
    LyricString* got0 = NULL;
    int rc0 = 2;
    for (int i = 0; i < 500 && rc0 == 2; i++) {
        rc0 = lyric_process_piped_read_line_within(r, &got0, 0);
        if (rc0 == 2) usleep(10000);
    }
    CHECK(rc0 == 1);
    if (rc0 == 1) {
        CHECK(lyric_string_len(got0) == 5);
        CHECK(memcmp(LYRIC_STRING_DATA(got0), "ready", 5) == 0);
        lyric_release(got0);
    }
    LyricString* empty = NULL;
    CHECK(lyric_process_piped_read_line_within(r, &empty, 0) == 2);
    CHECK(lyric_process_piped_close_stdin(r) == 0);
    CHECK(lyric_process_piped_wait_exit(r, 5000) == 1);
    lyric_process_piped_close(r);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_burst_in_order(void) {
    /* 5000 lines from one `seq` burst (#7277): every line returned in
     * order, with CR-free content, and end-of-stream afterwards. */
    LyricList* args = lyric_list_new(2);
    LyricString* a1 = mk_str("1");
    LyricString* a2 = mk_str("5000");
    lyric_list_push(args, (int64_t)(intptr_t)a1);
    lyric_list_push(args, (int64_t)(intptr_t)a2);
    lyric_release(a1);
    lyric_release(a2);

    void* p = lyric_process_piped_spawn("seq", args);
    lyric_release(args);
    CHECK(p != NULL);

    char expect[16];
    int ok = 1;
    for (int n = 1; n <= 5000; n++) {
        LyricString* got = NULL;
        if (lyric_process_piped_read_line(p, &got) != 1) { ok = 0; break; }
        int len = snprintf(expect, sizeof(expect), "%d", n);
        if (lyric_string_len(got) != len || memcmp(LYRIC_STRING_DATA(got), expect, (size_t)len) != 0) ok = 0;
        lyric_release(got);
        if (!ok) break;
    }
    CHECK(ok);
    LyricString* none = NULL;
    CHECK(lyric_process_piped_read_line(p, &none) == 0);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    lyric_process_piped_close(p);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_crlf_stripped(void) {
    /* A CRLF-terminated line (printf "a\r\nb\n") must have the \r
     * stripped, matching .NET's StreamReader.ReadLine()/the JVM twin's
     * documented CRLF convention. */
    LyricList* args = lyric_list_new(2);
    LyricString* fmt = mk_str("%s");
    LyricString* body = mk_str("a\r\nb\n");
    lyric_list_push(args, (int64_t)(intptr_t)fmt);
    lyric_list_push(args, (int64_t)(intptr_t)body);
    lyric_release(fmt);
    lyric_release(body);

    void* p = lyric_process_piped_spawn("/usr/bin/printf", args);
    lyric_release(args);
    CHECK(p != NULL);

    LyricString* got1 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got1) == 1);
    CHECK(lyric_string_len(got1) == 1);
    CHECK(memcmp(LYRIC_STRING_DATA(got1), "a", 1) == 0);
    lyric_release(got1);

    LyricString* got2 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got2) == 1);
    CHECK(lyric_string_len(got2) == 1);
    CHECK(memcmp(LYRIC_STRING_DATA(got2), "b", 1) == 0);
    lyric_release(got2);

    LyricString* got3 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got3) == 0);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    lyric_process_piped_close(p);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_kill(void) {
    /* A long-sleeping child, killed outright: is_alive flips to dead,
     * exit code reports signal termination, and kill on an
     * already-reaped handle is a harmless no-op (idempotent-safe, like
     * lyric_process_kill). */
    LyricList* argv = lyric_list_new(2);
    LyricString* dash_c = mk_str("-c");
    LyricString* script = mk_str("sleep 30");
    lyric_list_push(argv, (int64_t)(intptr_t)dash_c);
    lyric_list_push(argv, (int64_t)(intptr_t)script);
    lyric_release(dash_c);
    lyric_release(script);

    void* p = lyric_process_piped_spawn("/bin/sh", argv);
    lyric_release(argv);
    CHECK(p != NULL);
    CHECK(lyric_process_piped_is_alive(p) == 1);
    /* Not yet exited: a short wait must time out, not block forever. */
    CHECK(lyric_process_piped_wait_exit(p, 50) == 0);

    CHECK(lyric_process_piped_kill(p) == 0);
    CHECK(lyric_process_piped_is_alive(p) == 0);
    CHECK(lyric_process_piped_exit_code(p) == 128 + SIGKILL);
    CHECK(lyric_process_piped_kill(p) == 0); /* already reaped: no-op */
    lyric_process_piped_close(p);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_spawn_failure(void) {
    /* A nonexistent executable: execvp fails inside the child, which
     * reports it over the exec-failure pipe, so spawn returns NULL (the
     * managed twins' Process.Start / ProcessBuilder.start throw here). */
    void* p = lyric_process_piped_spawn("/nonexistent-lyric-rt-piped-exe", NULL);
    CHECK(p == NULL);
    CHECK(lyric_process_last_spawn_errno() == ENOENT);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_stderr_inherited(void) {
    /* The headline contract this kernel exists to preserve (module
     * header): stderr is NEVER piped here, so a child that writes a lot
     * to stderr cannot deadlock against a full, undrained capture pipe
     * the way a naive stdout+stderr+stdin piped model would. Route the
     * child's stderr to a real fd (a temp file) via a shell redirection
     * and confirm the bytes land there -- proving stderr was inherited
     * from THIS process's fd table, not captured by the kernel. */
    char tmpl[] = "/tmp/lyric_rt_piped_stderr_XXXXXX";
    int fd = mkstemp(tmpl);
    CHECK(fd >= 0);
    int saved_stderr = dup(STDERR_FILENO);
    CHECK(saved_stderr >= 0);
    CHECK(dup2(fd, STDERR_FILENO) >= 0);
    close(fd);

    LyricList* argv = lyric_list_new(2);
    LyricString* dash_c = mk_str("-c");
    LyricString* script = mk_str("echo err-side 1>&2");
    lyric_list_push(argv, (int64_t)(intptr_t)dash_c);
    lyric_list_push(argv, (int64_t)(intptr_t)script);
    lyric_release(dash_c);
    lyric_release(script);
    void* p = lyric_process_piped_spawn("/bin/sh", argv);
    lyric_release(argv);
    CHECK(p != NULL);
    CHECK(lyric_process_piped_wait_exit(p, 5000) == 1);
    CHECK(lyric_process_piped_exit_code(p) == 0);
    /* Nothing was ever written to the piped stdout. */
    LyricString* got = NULL;
    CHECK(lyric_process_piped_read_line(p, &got) == 0);
    lyric_process_piped_close(p);

    CHECK(dup2(saved_stderr, STDERR_FILENO) >= 0);
    close(saved_stderr);
    char buf[64];
    memset(buf, 0, sizeof(buf));
    int rfd = open(tmpl, O_RDONLY);
    CHECK(rfd >= 0);
    ssize_t n = read(rfd, buf, sizeof(buf) - 1);
    close(rfd);
    unlink(tmpl);
    CHECK(n > 0);
    CHECK(strstr(buf, "err-side") != NULL);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_double_close(void) {
    /* Issue #6975: an earlier version of lyric_process_piped_close
     * unconditionally free()'d the handle, so a second call on the same
     * pointer -- exactly the "safe to call during best-effort cleanup"
     * scenario the function's own doc comment invites -- was a real
     * double-free/use-after-free. Calling it twice here must be a clean
     * no-op the second time, verified under ASan (no heap corruption, no
     * crash). */
    void* p = lyric_process_piped_spawn("/bin/cat", NULL);
    CHECK(p != NULL);
    lyric_process_piped_close(p);
    lyric_process_piped_close(p);
}
#endif /* !__wasi__ */

#ifndef __wasi__
static void test_process_piped_read_after_close_with_buffered_line(void) {
    /* Issue #6993: lyric_process_piped_close (the #6975 addendum) freed
     * linebuf.data and NULL'd it, but never reset linebuf.len -- so a
     * handle closed while a second, not-yet-consumed line was still
     * buffered left linebuf.len > 0 with linebuf.data == NULL. The very
     * next lyric_process_piped_read_line call on that handle then
     * dereferenced a NULL pointer in its "scan for '\n'" loop instead of
     * safely reporting "no more lines". `printf "a\nb\n"` writes both
     * lines in one shot, so the first read_line call is expected to pull
     * both into linebuf, return "a", and leave "b\n" buffered
     * (linebuf.len > 0) -- exactly the state that reproduced the bug. */
    LyricList* args = lyric_list_new(2);
    LyricString* fmt = mk_str("%s");
    LyricString* body = mk_str("a\nb\n");
    lyric_list_push(args, (int64_t)(intptr_t)fmt);
    lyric_list_push(args, (int64_t)(intptr_t)body);
    lyric_release(fmt);
    lyric_release(body);

    void* p = lyric_process_piped_spawn("/usr/bin/printf", args);
    lyric_release(args);
    CHECK(p != NULL);

    LyricString* got1 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got1) == 1);
    CHECK(lyric_string_len(got1) == 1);
    CHECK(memcmp(LYRIC_STRING_DATA(got1), "a", 1) == 0);
    lyric_release(got1);

    lyric_process_piped_close(p);

    /* Must return 0 (no more lines) cleanly, not NULL-deref. */
    LyricString* got2 = NULL;
    CHECK(lyric_process_piped_read_line(p, &got2) == 0);
}
#endif /* !__wasi__ */

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

#ifndef __wasi__
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
#endif /* !__wasi__ */

/* Body: await a task that can never complete (its "coroutine" was
 * never driven past RUNNING) — the deadlock detector must abort. */
#ifndef __wasi__
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
#endif /* !__wasi__ */

static LyricString* rt_str(const char* s) {
    return lyric_string_from_literal((const uint8_t*)s, (int64_t)strlen(s));
}

/* lyric_thread_spawn_detached runs the entry on its own thread and releases
 * the caller's retain on `arg` once the entry returns -- no join, no leak. */
#ifndef __wasi__
static volatile int detached_ran = 0;
static void* detached_entry(void* arg) {
    (void)arg;
    detached_ran = 1;
    return NULL;
}

static void test_thread_spawn_detached(void) {
    LyricObjectHeader* h = (LyricObjectHeader*)lyric_alloc(sizeof(LyricObjectHeader));
    atomic_store(&h->rc, 2); /* the creator's reference plus the thread's */
    lyric_weak_init(h);
    h->dtor = counting_dtor;
    dtor_calls = 0;
    detached_ran = 0;
    CHECK(lyric_thread_spawn_detached(detached_entry, h) == 0);
    struct timespec ts = {0, 1000000};
    for (int i = 0; i < 5000 && atomic_load(&h->rc) != 1; i++) {
        nanosleep(&ts, NULL);
    }
    CHECK(detached_ran == 1);
    CHECK(atomic_load(&h->rc) == 1);
    CHECK(dtor_calls == 0);
    lyric_release(h);
    CHECK(dtor_calls == 1);
}
#endif

/* The per-thread slot retains what it holds, releases the previous object on
 * replace and on clear, and reports whether it holds one. */
static void test_thread_ref_slot(void) {
    LyricObjectHeader* a = (LyricObjectHeader*)lyric_alloc(sizeof(LyricObjectHeader));
    atomic_store(&a->rc, 1);
    lyric_weak_init(a);
    a->dtor = counting_dtor;
    dtor_calls = 0;
    CHECK(lyric_thread_ref_has() == 0);
    lyric_thread_ref_set(a);
    CHECK(lyric_thread_ref_has() == 1);
    CHECK(lyric_thread_ref_get() == a);
    CHECK(atomic_load(&a->rc) == 3);
    lyric_release(a);
    CHECK(atomic_load(&a->rc) == 2);
    lyric_thread_ref_set(a);
    CHECK(atomic_load(&a->rc) == 2);
    lyric_thread_ref_clear();
    CHECK(lyric_thread_ref_has() == 0);
    CHECK(atomic_load(&a->rc) == 1);
    lyric_global_lock();
    lyric_global_unlock();
    lyric_release(a);
    CHECK(dtor_calls == 1);
}

static void test_string_ascii_case_compare(void) {
    CHECK(lyric_string_ascii_case_compare(rt_str("Content-Length"), rt_str("content-length")) == 1);
    CHECK(lyric_string_ascii_case_compare(rt_str("Host"), rt_str("host")) == 1);
    CHECK(lyric_string_ascii_case_compare(rt_str(""), rt_str("")) == 1);
    CHECK(lyric_string_ascii_case_compare(rt_str("Host"), rt_str("Hosts")) == 0);
    CHECK(lyric_string_ascii_case_compare(rt_str("abc"), rt_str("abd")) == 0);
    CHECK(lyric_string_ascii_case_compare(rt_str("[a]"), rt_str("{A}")) == 0);
    CHECK(lyric_string_ascii_case_compare(rt_str("caf\xc3\xa9"), rt_str("CAF\xc3\x89")) == -1);
    CHECK(lyric_string_ascii_case_compare(rt_str("abc"), rt_str("ab\xc3\xa9")) == -1);
    CHECK(lyric_string_ascii_case_compare(rt_str("ab"), rt_str("abc\xc3\xa9")) == -1);
}

int main(void) {
#ifndef __wasi__
    test_thread_spawn_detached();
#endif
    test_thread_ref_slot();
    test_string_ascii_case_compare();
    test_alloc_retain_release();
    test_free();
    test_allocated_bytes();
    test_strings();
    test_string_trim_case_search();
    test_string_index_of_from_concat_list();
    test_weak();
    test_weak_uaf();
    test_weak_liveness();
    test_list_scalars();
    test_list_refs();
    test_map_int_keys();
    test_map_tombstone_churn();
    test_map_shrinks_on_removal();
    test_map_set_purge_shrinks();
    test_list_append_all();
    test_map_string_keys();
    test_list_copy();
    test_list_slice_concat_append();
    test_list_bulk_builders();
#ifndef __wasi__
    test_list_slice_oob_aborts();
#endif
#ifndef __wasi__
    test_string_char_at_oob_aborts();
#endif
#ifndef __wasi__
    test_string_char_at_non_bmp_aborts();
#endif
    test_read_bytes();
    test_write_bytes();
#ifndef __wasi__
    test_stdin_lines_and_bytes();
#endif
#ifndef __wasi__
    test_stdin_wait_times_out();
#endif
    test_dir_list2();
#ifndef __wasi__
    test_dir_list_typed();
#endif
#ifndef __wasi__
    test_is_dir_nofollow();
#endif
    test_args();
    test_map_keys_values();
    test_posix();
#ifndef __wasi__
    test_semaphore();
    test_condition_variable();
    test_monitor();
    test_global_condition();
#endif
    test_ok_variants();
    test_uuid_v4();
    test_file_io();
    test_file_mtime();
    test_directories();
#ifndef __wasi__
    test_console_write_line();
#endif
#ifndef __wasi__
    test_console_write_bytes();
#endif
    test_environment();
#ifndef __wasi__
    test_process();
#endif
#ifndef __wasi__
    test_process_closed_stdio();
#endif
#ifndef __wasi__
    test_process_closed_stdin_stdout();
#endif
#ifndef __wasi__
    test_process_op_basic();
#endif
#ifndef __wasi__
    test_process_op_kill();
#endif
#ifndef __wasi__
    test_process_op_kill_after_exit();
#endif
#ifndef __wasi__
    test_process_op_exec_failure();
#endif
#ifndef __wasi__
    test_process_stdin_roundtrip();
#endif
#ifndef __wasi__
    test_process_stdin_large_no_deadlock();
#endif
#ifndef __wasi__
    test_process_stdin_child_ignores();
#endif
#ifndef __wasi__
    test_process_sync_timeout();
#endif
#ifndef __wasi__
    test_process_sync_timeout_pending_stdin();
#endif
#ifndef __wasi__
    test_process_sync_timeout_grandchild_writer();
#endif
#ifndef __wasi__
    test_process_sync_timeout_setsid_escapee();
#endif
#ifndef __wasi__
    test_process_op_stdin();
#endif
#ifndef __wasi__
    test_process_piped_line_roundtrip();
#endif
#ifndef __wasi__
    test_process_run_inherited();
#endif
    test_string_replace();
#ifndef __wasi__
    test_process_piped_final_line_without_newline();
#endif
#ifndef __wasi__
    test_process_piped_read_line_within();
#endif
#ifndef __wasi__
    test_process_piped_burst_in_order();
#endif
#ifndef __wasi__
    test_process_piped_crlf_stripped();
#endif
#ifndef __wasi__
    test_process_piped_kill();
#endif
#ifndef __wasi__
    test_process_piped_spawn_failure();
#endif
#ifndef __wasi__
    test_process_piped_stderr_inherited();
#endif
#ifndef __wasi__
    test_process_piped_double_close();
#endif
#ifndef __wasi__
    test_process_piped_read_after_close_with_buffered_line();
#endif
    test_async_hot_completion();
    test_async_block_on_sleep();
    test_async_interleave();
    test_async_await_chain();
    test_async_multi_waiters();
#ifndef __wasi__
    test_async_sleep_saturates();
#endif
#ifndef __wasi__
    test_async_deadlock_aborts();
#endif
    if (failures == 0) {
        printf("lyric_rt_test: all tests passed\n");
        return 0;
    }
    fprintf(stderr, "lyric_rt_test: %d failure(s)\n", failures);
    return 1;
}
