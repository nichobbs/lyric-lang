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

/* free() for a raw lyric_alloc buffer that is NOT an ARC object (no header).
 * Used for a protected type's runtime-sized mutex buffer (D-N-017); ARC
 * objects are freed by lyric_release, never this. */
void lyric_free(void* p);

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
/* Fresh rc=1 shallow copy: same elems_are_refs flag; ref elements are
 * retained by the copy.  Backs slice[T] <-> List[T] bridging (the two
 * share this representation on the native target, D-N-015) and the
 * snapshot semantics of `.toArray()`.  A NULL `src` defensively yields
 * a fresh empty scalar list rather than crashing (#4851). */
LyricList* lyric_list_copy(LyricList* src);
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
/* Fresh rc=1 snapshot lists of the occupied keys / values (entries
 * retained by the list when ref-typed).  O(capacity), not O(len):
 * each walks every bucket of the open-addressing table, occupied or
 * not — fine for the compiler's small maps, worth knowing before
 * calling in a hot loop over a map that grew large and then shrank. */
LyricList* lyric_map_keys(LyricMap* map);
LyricList* lyric_map_values(LyricMap* map);
void      lyric_map_dtor(void* obj);

/* ── Console (lyric_posix.c) ───────────────────────────────────────── */

/* Write the whole string (resp. one '\n') to the file descriptor,
 * retrying on EINTR and partial writes.  Best-effort: errors other
 * than EINTR abandon the write (console output is a best-effort
 * effect in Lyric — see Std.Console). */
void lyric_console_write(int32_t fd, LyricString* s);
void lyric_console_write_newline(int32_t fd);

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

/* ── Files (lyric_fs.c) ────────────────────────────────────────────────
 *
 * `path` (and `old_path`/`new_path`) are NUL-terminated C strings — the
 * `_kernel_native/` wrapper obtains them via lyric_string_to_cstring /
 * withCString, the same convention as lyric_file_size above. All of
 * these are environmental-failure functions: they return -1 or NULL on
 * any OS-level failure (permissions, missing path, ...) and never panic.
 */

/* open(2) wrapper; retries on EINTR.  Returns the fd, or -1 on failure. */
int32_t lyric_file_open(const char* path, int32_t flags, int32_t mode);

/* close(2) wrapper.  Not retried on EINTR: on Linux and macOS the fd is
 * closed regardless of an EINTR return, so retrying risks closing an
 * unrelated fd reused by another thread.  Returns 0 on success, -1 on
 * failure. */
int32_t lyric_file_close(int32_t fd);

/* Reads the whole file at `path` into one fresh rc=1 LyricString.
 * Returns NULL if the file cannot be opened or read. */
LyricString* lyric_file_read_all(const char* path);

/* Status-returning variant for Lyric kernels (out-param via
 * nativeAddrOf): 0 and *out set on success; -1 on failure with *out
 * untouched. */
int32_t lyric_file_read_all_ok(const char* path, LyricString** out);

/* Whole-file read as a scalar LyricList, one byte per 64-bit slot (the
 * documented Phase-1 tradeoff for the single list layout, D-N-015).
 * ALWAYS returns a fresh rc=1 list (empty on failure); *ok reports
 * success (1/0).
 *
 * `ok` is int32_t*, not int64_t*, ON PURPOSE (#4844): the Lyric caller
 * passes `NativePtr[Int]` (a zero-initialised i64 slot via nativeAddrOf).
 * A 4-byte write lands the 0/1 flag in the low half; the high half stays
 * 0, so the i64 read is exact on every Phase-1 target (all little-endian
 * — D-N-008).  Widening to int64_t* is blocked on a codegen bug where an
 * 8-byte write through nativeAddrOf(var: Int) corrupts an adjacent stack
 * temp (#4845); revisit once that is fixed. */
LyricList* lyric_file_read_bytes(const char* path, int32_t* ok);

/* Write every byte (one per 64-bit slot) of `data` to `path`; append
 * != 0 appends, else truncate-or-create (0644).  0 on success, -1 on
 * failure. */
int32_t lyric_file_write_bytes(const char* path, LyricList* data, int32_t append);

/* Writes every byte of `data` to `path`, creating the file (mode 0644)
 * if it does not exist.  `append` != 0 appends to an existing file;
 * otherwise the file is truncated first.  Returns 0 on success, -1 on
 * failure. */
int32_t lyric_file_write_all(const char* path, LyricString* data, int32_t append);

/* unlink(2) wrapper.  Returns 0 on success, -1 on failure. */
int32_t lyric_file_delete(const char* path);

/* rename(2) wrapper.  Returns 0 on success, -1 on failure. */
int32_t lyric_file_rename(const char* old_path, const char* new_path);

/* Returns 1 if `path` exists and is a regular file, 0 otherwise
 * (including a stat(2) failure or a non-regular-file path). */
int32_t lyric_file_exists(const char* path);

/* ── Directories (lyric_fs.c) ──────────────────────────────────────── */

/* mkdir(2) wrapper; single level only (no `mkdir -p`), mode 0755.
 * Returns 0 on success, -1 on failure. */
int32_t lyric_dir_create(const char* path);

/* rmdir(2) wrapper; the directory must be empty.  Returns 0 on success,
 * -1 on failure. */
int32_t lyric_dir_remove(const char* path);

/* Returns 1 if `path` exists and is a directory, 0 otherwise.  Follows
 * symlinks (stat), so a symlink to a directory counts as a directory. */
int32_t lyric_dir_exists(const char* path);

/* Returns 1 iff `path` is itself a directory WITHOUT following symlinks
 * (lstat); a symlink-to-directory returns 0.  Used by recursive delete
 * to unlink symlinks instead of descending into their targets. */
int32_t lyric_path_is_dir_nofollow(const char* path);

/* Lists the entries of the directory at `path` (skipping "." and
 * ".."), returning a fresh rc=1 LyricList of rc=1 LyricString* names
 * (list constructed with elems_are_refs = 1). Returns NULL if the
 * directory cannot be opened or a read error occurs partway through. */
LyricList* lyric_dir_list(const char* path);

/* Entry-name listing with the return-plus-ok-flag protocol: always a
 * fresh rc=1 list (empty on failure); *ok reports success (1/0).  `ok`
 * is int32_t* by design — see lyric_file_read_bytes (#4844, #4845). */
LyricList* lyric_dir_list2(const char* path, int32_t* ok);

/* ── Environment (lyric_fs.c) ──────────────────────────────────────── */

/* getenv(3) wrapper.  Returns a fresh rc=1 LyricString copy of the
 * value, or NULL if the variable is unset. */
LyricString* lyric_env_get(const char* name);

/* Status-returning variant for Lyric kernels: 0 and *out set when the
 * variable exists; -1 otherwise with *out untouched. */
int32_t lyric_env_get_ok(const char* name, LyricString** out);

/* setenv(3) wrapper (always overwrites an existing value).  Returns 0
 * on success, -1 on failure. */
int32_t lyric_env_set(const char* name, const char* value);

/* getcwd(3) wrapper.  Returns a fresh rc=1 LyricString, or NULL on
 * failure. */
LyricString* lyric_env_cwd(void);

/* Status-returning variant for Lyric kernels: 0 and *out set on
 * success; -1 on failure with *out untouched. */
int32_t lyric_env_cwd_ok(LyricString** out);

/* ── Process arguments ─────────────────────────────────────────────── */

/* Capture argc/argv at process entry (the synthesised C main calls
 * this before Lyric main runs). */
void lyric_args_set(int32_t argc, char** argv);

/* Fresh rc=1 list of the captured argv strings (including argv[0],
 * the managed GetCommandLineArgs convention); empty if never set. */
LyricList* lyric_args_get(void);

/* ── Process execution (lyric_process.c) ───────────────────────────── */

/* Runs `path` via fork + execvp (never a shell — no interpolation of
 * `path` or any argument), with argv built from `path` (as argv[0])
 * followed by the LyricString* elements of `args` in order.  `args`
 * may be NULL, meaning no arguments beyond argv[0].  stdout and stderr
 * are captured in full into fresh rc=1 LyricStrings.
 *
 * Returns 0 when the child was spawned and reaped successfully: then
 * *out_exit_code holds the child's exit status (a signal-terminated
 * child reports 128 + signal number, the shell convention),
 * *out_stdout and *out_stderr hold the captured output (ownership
 * transferred to the caller).  Returns -1 on a spawn/wait failure
 * (pipe/fork/waitpid failure); the out-params are left untouched. An
 * execvp failure inside the child (e.g. `path` not found) is not a
 * spawn failure: it is reported as exit code 127 with empty output,
 * matching shell convention. */
int32_t lyric_process_run(const char* path, LyricList* args,
                           int32_t* out_exit_code,
                           LyricString** out_stdout,
                           LyricString** out_stderr);

#ifdef __cplusplus
}
#endif

#endif /* LYRIC_RT_H */
