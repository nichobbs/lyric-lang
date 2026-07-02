/* lyric_rt.h — public header for the Lyric native runtime (lyric_rt.a).
 *
 * The runtime provides the four cross-cutting ARC intrinsics (D-N-011),
 * the string representation (D-N-006), weak-reference upgrade support,
 * the List/Map collection kernels (D-N-012), and the platform helpers
 * that abstract POSIX constants and struct layouts that differ between
 * Linux and macOS (native/plan/05-ffi-design.md).
 *
 * Every heap-allocated Lyric value begins with the two-word
 * LyricObjectHeader; header offset is 0 so (void*)obj is the header.
 * Objects whose rc equals INT32_MAX are static (string literals,
 * zero-capture closures) and are never retained, released, or freed.
 */
#ifndef LYRIC_RT_H
#define LYRIC_RT_H

#include <stdatomic.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Object header ─────────────────────────────────────────────────── */

typedef struct {
    _Atomic int32_t rc;    /* reference count; INT32_MAX = static sentinel */
    void (*dtor)(void*);   /* destructor; may be NULL; must not free(obj)  */
} LyricObjectHeader;

/* ── ARC intrinsics (D-N-011) ──────────────────────────────────────── */

/* malloc + abort-on-OOM.  All Lyric heap allocation goes through here. */
void* lyric_alloc(uint64_t size);

/* Atomic rc increment.  No-op on NULL and on static objects. */
void lyric_retain(void* obj);

/* Atomic rc decrement; at zero runs the destructor then frees the
 * allocation.  No-op on NULL and on static objects. */
void lyric_release(void* obj);

/* Writes "lyric panic at <file>:<line>: <msg>" to stderr and aborts. */
_Noreturn void lyric_panic_msg(const char* msg, const char* file, int32_t line);

/* ── Strings (D-N-006) ─────────────────────────────────────────────── */

/* UTF-8 bytes follow the struct inline in the same allocation. */
typedef struct {
    _Atomic int32_t rc;
    void (*dtor)(void*);
    int64_t len;   /* byte count of the UTF-8 data (no terminator)       */
    int64_t cap;   /* allocated data bytes (>= len; may include a NUL)   */
} LyricString;

#define LYRIC_STRING_DATA(s) ((uint8_t*)((LyricString*)(s) + 1))

LyricString* lyric_string_from_literal(const uint8_t* data, int64_t len);
LyricString* lyric_string_concat(LyricString* a, LyricString* b);
int64_t      lyric_string_len(LyricString* s);
uint8_t      lyric_string_byte_at(LyricString* s, int64_t idx);
int32_t      lyric_string_eq(LyricString* a, LyricString* b);
int32_t      lyric_string_cmp(LyricString* a, LyricString* b);
void         lyric_string_dtor(void* obj);

/* Integer / float formatting helpers used by the codegen's toString
 * lowering.  Each returns a fresh rc=1 string. */
LyricString* lyric_string_from_int(int64_t v);
LyricString* lyric_string_from_float(double v);
LyricString* lyric_string_from_bool(int32_t v);
LyricString* lyric_string_from_char(int32_t codepoint);
LyricString* lyric_string_substring(LyricString* s, int64_t start, int64_t len);

/* NUL-terminated copy of the string data (malloc'd; pair with
 * lyric_cstring_free).  For C APIs taking const char*. */
const char* lyric_string_to_cstring(LyricString* s);
void        lyric_cstring_free(const char* p);

/* ── Weak references (04-arc-design.md §NativeWeak) ────────────────── */

/* Attempts to atomically increment rc iff it is still > 0.  Returns the
 * object pointer on success (caller now holds a strong ref), NULL when
 * the object is already dead.  Static objects always upgrade. */
void* lyric_weak_upgrade(void* raw);

/* ── Collections (D-N-012) ─────────────────────────────────────────── */

/* List: dynamic array.  Element ownership is declared at construction:
 * elems_are_refs != 0 means every element is an ARC pointer that the
 * list retains on push and releases on removal / destruction; 0 means
 * elements are scalar bit-patterns stored as-is (Int/Long/Float/Bool
 * widened to 64 bits by the codegen). */
typedef struct {
    _Atomic int32_t rc;
    void (*dtor)(void*);
    int64_t*        data;  /* 8-byte slots: scalars or pointers */
    int64_t         len;
    int64_t         cap;
    int32_t         elems_are_refs;
} LyricList;

LyricList* lyric_list_new(int32_t elems_are_refs);
void       lyric_list_push(LyricList* list, int64_t val);
int64_t    lyric_list_get(LyricList* list, int64_t idx);   /* panics OOB; does NOT retain */
void       lyric_list_set(LyricList* list, int64_t idx, int64_t val);
void       lyric_list_remove_at(LyricList* list, int64_t idx);
int64_t    lyric_list_len(LyricList* list);
void       lyric_list_clear(LyricList* list);
void       lyric_list_dtor(void* obj);

/* Map: open-addressing hash map.  Keys are either LyricString* (hashed
 * with SipHash-2-4 over the UTF-8 data) or 64-bit scalars (Fibonacci
 * hashing), chosen at construction.  Values follow the same
 * refs-vs-scalars rule as lists. */
typedef struct LyricMap LyricMap;

LyricMap* lyric_map_new(int32_t keys_are_strings, int32_t vals_are_refs);
void      lyric_map_set(LyricMap* map, int64_t key, int64_t val);
/* Returns 1 and writes the value through out_val when present; 0 otherwise. */
int32_t   lyric_map_get(LyricMap* map, int64_t key, int64_t* out_val);
int32_t   lyric_map_contains(LyricMap* map, int64_t key);
int32_t   lyric_map_remove(LyricMap* map, int64_t key);
int64_t   lyric_map_len(LyricMap* map);
void      lyric_map_dtor(void* obj);

/* ── Platform helpers (lyric_posix.c) ──────────────────────────────── */

/* open(2) flag values differ across platforms (O_CREAT is 0x40 on Linux,
 * 0x200 on macOS); expose them as functions so the Lyric kernel layer
 * never hardcodes a platform table. */
int32_t lyric_o_rdonly(void);
int32_t lyric_o_wronly(void);
int32_t lyric_o_rdwr(void);
int32_t lyric_o_creat(void);
int32_t lyric_o_trunc(void);
int32_t lyric_o_append(void);

/* st_size via stat(2) — the stat struct layout is architecture-specific,
 * so the kernel layer calls this instead of declaring stat directly.
 * Returns -1 when the path cannot be stat'ed. */
int64_t lyric_file_size(const char* path);

/* sizeof(pthread_mutex_t) for the running platform, so protected-type
 * codegen can size the inline mutex slot without a hardcoded table. */
int32_t lyric_mutex_size(void);

/* pthread_mutex wrappers for protected types.  `m` points at the inline
 * mutex slot inside the protected object. */
void lyric_mutex_init(void* m);
void lyric_mutex_lock(void* m);
void lyric_mutex_unlock(void* m);
void lyric_mutex_destroy(void* m);

/* Milliseconds since the Unix epoch (CLOCK_REALTIME). */
int64_t lyric_epoch_millis(void);
/* Monotonic nanoseconds (CLOCK_MONOTONIC). */
int64_t lyric_monotonic_nanos(void);

/* Fill buf with n cryptographically secure random bytes.  Returns 0 on
 * success, -1 on failure.  getrandom(2) on Linux, getentropy on macOS. */
int32_t lyric_secure_random(uint8_t* buf, int64_t n);

#ifdef __cplusplus
}
#endif

#endif /* LYRIC_RT_H */
