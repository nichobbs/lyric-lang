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
#include <math.h>
#include <stddef.h>
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
    atomic_store_explicit(&s->weak, 1, memory_order_relaxed);
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
    /* Canonical non-finite spellings, matching the managed targets
     * (platform printf casing varies: nan/NAN, inf/INF). */
    if (isnan(v)) return lyric_string_from_literal((const uint8_t*)"NaN", 3);
    if (isinf(v)) {
        if (v > 0) return lyric_string_from_literal((const uint8_t*)"Infinity", 8);
        return lyric_string_from_literal((const uint8_t*)"-Infinity", 9);
    }
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

/* Encodes one Unicode scalar value as UTF-8 into `out` (>= 4 bytes) and
 * returns the byte count (1-4).  Shared by lyric_string_from_char and the
 * `.toLower()` re-encode path below. */
static int utf8_encode(uint32_t cp, uint8_t out[4]) {
    if (cp < 0x80) {
        out[0] = (uint8_t)cp;
        return 1;
    } else if (cp < 0x800) {
        out[0] = (uint8_t)(0xC0 | (cp >> 6));
        out[1] = (uint8_t)(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = (uint8_t)(0xE0 | (cp >> 12));
        out[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (uint8_t)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (uint8_t)(0xF0 | (cp >> 18));
    out[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (uint8_t)(0x80 | (cp & 0x3F));
    return 4;
}

/* Decodes the UTF-8 sequence at data[i] (0 <= i < len).  On a well-formed
 * sequence sets *cp and *valid = 1, returning its length (1-4).  On a
 * malformed lead byte or a truncated trailing sequence, sets *cp to the raw
 * byte value, *valid = 0, and returns 1 — callers must advance by exactly
 * one byte and must not re-encode an invalid decode (it was never a real
 * code point). */
static int utf8_decode_at(const uint8_t* data, int64_t len, int64_t i, uint32_t* cp, int* valid) {
    uint8_t b0 = data[i];
    *valid = 1;
    if (b0 < 0x80) {
        *cp = b0;
        return 1;
    }
    if ((b0 & 0xE0) == 0xC0 && i + 1 < len && (data[i + 1] & 0xC0) == 0x80) {
        *cp = ((uint32_t)(b0 & 0x1F) << 6) | (uint32_t)(data[i + 1] & 0x3F);
        return 2;
    }
    if ((b0 & 0xF0) == 0xE0 && i + 2 < len && (data[i + 1] & 0xC0) == 0x80 && (data[i + 2] & 0xC0) == 0x80) {
        *cp = ((uint32_t)(b0 & 0x0F) << 12) | ((uint32_t)(data[i + 1] & 0x3F) << 6) | (uint32_t)(data[i + 2] & 0x3F);
        return 3;
    }
    if ((b0 & 0xF8) == 0xF0 && i + 3 < len && (data[i + 1] & 0xC0) == 0x80 && (data[i + 2] & 0xC0) == 0x80 &&
        (data[i + 3] & 0xC0) == 0x80) {
        *cp = ((uint32_t)(b0 & 0x07) << 18) | ((uint32_t)(data[i + 1] & 0x3F) << 12) |
              ((uint32_t)(data[i + 2] & 0x3F) << 6) | (uint32_t)(data[i + 3] & 0x3F);
        return 4;
    }
    *cp = b0;
    *valid = 0;
    return 1;
}

/* The exact Unicode White_Space code-point set used by
 * `lyric-stdlib/std/char.l::isWhiteSpace` — kept byte-for-byte in sync by
 * hand (this runtime does not depend on the self-hosted stdlib) so
 * `.trim()` agrees with `Std.Char.isWhiteSpace` on every target. */
static int cp_is_lyric_whitespace(uint32_t cp) {
    if (cp >= 0x09 && cp <= 0x0D) return 1;   /* HT, LF, VT, FF, CR */
    if (cp == 0x20) return 1;                 /* SPACE */
    if (cp == 0x85) return 1;                 /* NEL */
    if (cp == 0xA0) return 1;                 /* NO-BREAK SPACE */
    if (cp == 0x1680) return 1;               /* OGHAM SPACE MARK */
    if (cp >= 0x2000 && cp <= 0x200A) return 1;  /* EN QUAD … HAIR SPACE */
    if (cp == 0x2028) return 1;               /* LINE SEPARATOR */
    if (cp == 0x2029) return 1;               /* PARAGRAPH SEPARATOR */
    if (cp == 0x202F) return 1;               /* NARROW NO-BREAK SPACE */
    if (cp == 0x205F) return 1;               /* MEDIUM MATHEMATICAL SPACE */
    if (cp == 0x3000) return 1;               /* IDEOGRAPHIC SPACE */
    return 0;
}

LyricString* lyric_string_trim(LyricString* s) {
    int64_t len = s ? s->len : 0;
    const uint8_t* data = len > 0 ? LYRIC_STRING_DATA(s) : NULL;

    int64_t start = len;
    int64_t i = 0;
    while (i < len) {
        uint32_t cp;
        int valid;
        int n = utf8_decode_at(data, len, i, &cp, &valid);
        if (!(valid && cp_is_lyric_whitespace(cp))) {
            start = i;
            break;
        }
        i += n;
    }
    if (start == len) {
        return lyric_string_from_literal((const uint8_t*)"", 0);
    }

    /* `end` tracks the byte offset just past the last non-whitespace code
     * point seen so far; a single forward pass avoids needing to decode
     * UTF-8 backwards from the end of the string. */
    int64_t end = start;
    i = start;
    while (i < len) {
        uint32_t cp;
        int valid;
        int n = utf8_decode_at(data, len, i, &cp, &valid);
        i += n;
        if (!(valid && cp_is_lyric_whitespace(cp))) {
            end = i;
        }
    }
    return lyric_string_from_literal(data + start, end - start);
}

/* Full-Unicode-Character-Database *simple* case folding (#6779, widening
 * D-progress-831's five-script hand-written table): `kLowerTable`/
 * `kUpperTable` are generated from UnicodeData.txt's own "simple
 * lowercase/uppercase mapping" columns by
 * scripts/gen_unicode_case_tables.py — see
 * lyric_unicode_case_tables.inc's own header. Deliberately still not the
 * full `SpecialCasing.txt` rule set: no locale-conditional Turkish/Azeri
 * dotless-I folding of plain ASCII "I", no German ß -> "SS" expansion, no
 * final-sigma positional form — every mapping here is unconditional and
 * every output is a single scalar value (this runtime has no locale
 * concept and no 1-codepoint-to-N-codepoints case-conversion path). */
#include "lyric_unicode_case_tables.inc"

static uint32_t case_table_lookup(const CaseFoldEntry* table, size_t count, uint32_t cp) {
    size_t lo = 0;
    size_t hi = count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (table[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < count && table[lo].cp == cp) return table[lo].mapped;
    return cp;
}

static uint32_t cp_to_lower(uint32_t cp) {
    return case_table_lookup(kLowerTable, kLowerTable_count, cp);
}

static uint32_t cp_to_upper(uint32_t cp) {
    return case_table_lookup(kUpperTable, kUpperTable_count, cp);
}

typedef uint32_t (*CaseMapFn)(uint32_t);

/* Shared by `.toLower()`/`.toUpper()`.  Unlike the old five-script table
 * (which only ever shrank, and only for U+0130), the full UCD table maps
 * some code points to a DIFFERENT UTF-8 byte length in either direction,
 * so a single "allocate at the input's length" pass is no longer safe.
 * Two passes instead: the first computes the exact output byte length
 * (decoding each input code point and re-measuring its mapped UTF-8
 * length without writing anything), the second allocates exactly that
 * size and writes it — no upper-bound guess, no panic-on-overflow guard
 * needed. */
static LyricString* string_case_map(LyricString* s, CaseMapFn mapFn) {
    int64_t len = s ? s->len : 0;
    if (len == 0) return string_alloc(0);
    const uint8_t* src = LYRIC_STRING_DATA(s);

    int64_t outLen = 0;
    int64_t i = 0;
    while (i < len) {
        uint32_t cp;
        int valid;
        int n = utf8_decode_at(src, len, i, &cp, &valid);
        uint32_t mapped = valid ? mapFn(cp) : cp;
        if (mapped == cp) {
            outLen += n;
        } else {
            uint8_t tmp[4];
            outLen += utf8_encode(mapped, tmp);
        }
        i += n;
    }

    LyricString* out = string_alloc(outLen);
    uint8_t* dst = LYRIC_STRING_DATA(out);
    int64_t o = 0;
    i = 0;
    while (i < len) {
        uint32_t cp;
        int valid;
        int n = utf8_decode_at(src, len, i, &cp, &valid);
        uint32_t mapped = valid ? mapFn(cp) : cp;
        if (mapped == cp) {
            memcpy(dst + o, src + i, (size_t)n);
            o += n;
        } else {
            uint8_t buf[4];
            int m = utf8_encode(mapped, buf);
            memcpy(dst + o, buf, (size_t)m);
            o += m;
        }
        i += n;
    }
    return out;
}

LyricString* lyric_string_to_lower(LyricString* s) {
    return string_case_map(s, cp_to_lower);
}

LyricString* lyric_string_to_upper(LyricString* s) {
    return string_case_map(s, cp_to_upper);
}

/* Ordinal (byte-exact) substring search — matches this runtime's existing
 * byte-indexed `.length`/`.substring` model (D-N-006).  An empty needle
 * matches at offset 0, mirroring the dotnet/JVM twins' `IndexOf("")` /
 * `indexOf("")`. */
static int64_t find_substring(const uint8_t* hay, int64_t hlen, const uint8_t* needle, int64_t nlen) {
    if (nlen == 0) return 0;
    if (nlen > hlen) return -1;
    int64_t last = hlen - nlen;
    for (int64_t i = 0; i <= last; i++) {
        if (memcmp(hay + i, needle, (size_t)nlen) == 0) return i;
    }
    return -1;
}

int64_t lyric_string_index_of(LyricString* haystack, LyricString* needle) {
    int64_t hlen = haystack ? haystack->len : 0;
    int64_t nlen = needle ? needle->len : 0;
    const uint8_t* hay = hlen > 0 ? LYRIC_STRING_DATA(haystack) : NULL;
    const uint8_t* nee = nlen > 0 ? LYRIC_STRING_DATA(needle) : NULL;
    return find_substring(hay, hlen, nee, nlen);
}

int32_t lyric_string_contains(LyricString* haystack, LyricString* needle) {
    return lyric_string_index_of(haystack, needle) >= 0 ? 1 : 0;
}

int32_t lyric_string_starts_with(LyricString* s, LyricString* prefix) {
    int64_t slen = s ? s->len : 0;
    int64_t plen = prefix ? prefix->len : 0;
    if (plen == 0) return 1;
    if (plen > slen) return 0;
    return memcmp(LYRIC_STRING_DATA(s), LYRIC_STRING_DATA(prefix), (size_t)plen) == 0 ? 1 : 0;
}

int32_t lyric_string_ends_with(LyricString* s, LyricString* suffix) {
    int64_t slen = s ? s->len : 0;
    int64_t xlen = suffix ? suffix->len : 0;
    if (xlen == 0) return 1;
    if (xlen > slen) return 0;
    return memcmp(LYRIC_STRING_DATA(s) + (slen - xlen), LYRIC_STRING_DATA(suffix), (size_t)xlen) == 0 ? 1 : 0;
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
