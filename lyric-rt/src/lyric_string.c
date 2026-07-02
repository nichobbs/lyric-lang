/* lyric_string.c — LyricString operations (D-N-006).
 *
 * A string is one contiguous allocation: the LyricString header followed
 * inline by the UTF-8 bytes.  All constructors return rc=1 objects whose
 * ownership transfers to the caller (ARC Rule 6).  Concatenation and the
 * formatting helpers never release their inputs (the caller keeps its
 * ownership; ARC Rule 5 — arguments are borrows).
 */
#include "lyric_rt.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void lyric_string_dtor(void* obj) {
    /* The data is inline; nothing to release.  lyric_release frees the
     * allocation itself after this returns. */
    (void)obj;
}

static LyricString* string_alloc(int64_t len) {
    /* +1 so the data can always carry a trailing NUL, which makes
     * lyric_string_to_cstring cheap and debugger-friendly. */
    LyricString* s = (LyricString*)lyric_alloc(sizeof(LyricString) + (uint64_t)len + 1);
    atomic_store_explicit(&s->rc, 1, memory_order_relaxed);
    s->dtor = lyric_string_dtor;
    s->len = len;
    s->cap = len + 1;
    LYRIC_STRING_DATA(s)[len] = 0;
    return s;
}

LyricString* lyric_string_from_literal(const uint8_t* data, int64_t len) {
    LyricString* s = string_alloc(len);
    if (len > 0) memcpy(LYRIC_STRING_DATA(s), data, (size_t)len);
    return s;
}

LyricString* lyric_string_concat(LyricString* a, LyricString* b) {
    int64_t alen = a ? a->len : 0;
    int64_t blen = b ? b->len : 0;
    LyricString* s = string_alloc(alen + blen);
    if (alen > 0) memcpy(LYRIC_STRING_DATA(s), LYRIC_STRING_DATA(a), (size_t)alen);
    if (blen > 0) memcpy(LYRIC_STRING_DATA(s) + alen, LYRIC_STRING_DATA(b), (size_t)blen);
    return s;
}

int64_t lyric_string_len(LyricString* s) {
    return s ? s->len : 0;
}

uint8_t lyric_string_byte_at(LyricString* s, int64_t idx) {
    if (!s || idx < 0 || idx >= s->len) {
        lyric_panic_msg("string byte index out of bounds", "lyric_string.c", __LINE__);
    }
    return LYRIC_STRING_DATA(s)[idx];
}

int32_t lyric_string_eq(LyricString* a, LyricString* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    if (a->len != b->len) return 0;
    if (a->len == 0) return 1;
    return memcmp(LYRIC_STRING_DATA(a), LYRIC_STRING_DATA(b), (size_t)a->len) == 0;
}

int32_t lyric_string_cmp(LyricString* a, LyricString* b) {
    int64_t alen = a ? a->len : 0;
    int64_t blen = b ? b->len : 0;
    int64_t n = alen < blen ? alen : blen;
    if (n > 0) {
        int c = memcmp(LYRIC_STRING_DATA(a), LYRIC_STRING_DATA(b), (size_t)n);
        if (c != 0) return c < 0 ? -1 : 1;
    }
    if (alen == blen) return 0;
    return alen < blen ? -1 : 1;
}

LyricString* lyric_string_from_int(int64_t v) {
    char buf[24];
    int n = snprintf(buf, sizeof buf, "%" PRId64, v);
    if (n < 0) n = 0;
    if (n >= (int)sizeof buf) n = (int)sizeof buf - 1;
    return lyric_string_from_literal((const uint8_t*)buf, (int64_t)n);
}

LyricString* lyric_string_from_float(double v) {
    /* %.17g round-trips every IEEE 754 double; trim to the shortest
     * representation that still round-trips so output reads naturally. */
    char buf[40];
    int n = snprintf(buf, sizeof buf, "%.15g", v);
    double back = strtod(buf, NULL);
    if (back != v) {
        n = snprintf(buf, sizeof buf, "%.17g", v);
    }
    if (n < 0) n = 0;
    if (n >= (int)sizeof buf) n = (int)sizeof buf - 1;
    return lyric_string_from_literal((const uint8_t*)buf, (int64_t)n);
}

LyricString* lyric_string_from_bool(int32_t v) {
    return v ? lyric_string_from_literal((const uint8_t*)"true", 4)
             : lyric_string_from_literal((const uint8_t*)"false", 5);
}

LyricString* lyric_string_from_char(int32_t codepoint) {
    /* Encode one Unicode scalar value as UTF-8. */
    uint8_t buf[4];
    int64_t n;
    uint32_t c = (uint32_t)codepoint;
    if (c < 0x80) {
        buf[0] = (uint8_t)c;
        n = 1;
    } else if (c < 0x800) {
        buf[0] = (uint8_t)(0xC0 | (c >> 6));
        buf[1] = (uint8_t)(0x80 | (c & 0x3F));
        n = 2;
    } else if (c < 0x10000) {
        buf[0] = (uint8_t)(0xE0 | (c >> 12));
        buf[1] = (uint8_t)(0x80 | ((c >> 6) & 0x3F));
        buf[2] = (uint8_t)(0x80 | (c & 0x3F));
        n = 3;
    } else {
        buf[0] = (uint8_t)(0xF0 | (c >> 18));
        buf[1] = (uint8_t)(0x80 | ((c >> 12) & 0x3F));
        buf[2] = (uint8_t)(0x80 | ((c >> 6) & 0x3F));
        buf[3] = (uint8_t)(0x80 | (c & 0x3F));
        n = 4;
    }
    return lyric_string_from_literal(buf, n);
}

LyricString* lyric_string_substring(LyricString* s, int64_t start, int64_t len) {
    int64_t slen = s ? s->len : 0;
    if (start < 0 || len < 0 || start > slen || len > slen - start) {
        lyric_panic_msg("substring out of bounds", "lyric_string.c", __LINE__);
    }
    return lyric_string_from_literal(LYRIC_STRING_DATA(s) + start, len);
}

const char* lyric_string_to_cstring(LyricString* s) {
    int64_t len = s ? s->len : 0;
    char* buf = (char*)malloc((size_t)len + 1);
    if (!buf) lyric_panic_msg("OOM in lyric_string_to_cstring", "lyric_string.c", __LINE__);
    if (len > 0) memcpy(buf, LYRIC_STRING_DATA(s), (size_t)len);
    buf[len] = '\0';
    return buf;
}

void lyric_cstring_free(const char* p) {
    free((void*)p);
}
