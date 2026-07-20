/* lyric_rt.h — public header for the Lyric native runtime (lyric_rt.a).
 *
 * The runtime provides the four cross-cutting ARC intrinsics (D-N-011),
 * the string representation (D-N-006), weak-reference upgrade support,
 * the List/Map collection kernels (D-N-012), and the platform helpers
 * that abstract POSIX constants and struct layouts that differ between
 * Linux and macOS (native/plan/05-ffi-design.md).
 *
 * Every heap-allocated Lyric value begins with the LyricObjectHeader
 * (rc, weak count, dtor — 16 bytes); header offset is 0 so (void*)obj is
 * the header.  Objects whose rc equals INT32_MAX are static (string
 * literals, zero-capture closures) and are never retained, released,
 * weak-counted, or freed.
 */
#ifndef LYRIC_RT_H
#define LYRIC_RT_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Object header ─────────────────────────────────────────────────── */

typedef struct {
    _Atomic int32_t rc;    /* strong reference count; INT32_MAX = static sentinel */
    _Atomic int32_t weak;  /* weak-ref count, plus 1 while any strong ref lives;
                            * occupies the former alignment padding at offset 4,
                            * so sizeof and every later field offset are unchanged */
    void (*dtor)(void*);   /* destructor; may be NULL; must not free(obj)  */
} LyricObjectHeader;

/* The whole point of putting `weak` in the alignment padding between `rc` and
 * `dtor` is that the header stays two words and `dtor` keeps its offset, so the
 * codegen's `{ i32, ptr, <fields...> }` struct model and every downstream field
 * offset are unchanged from the pre-weak-count layout (#5504 / #5546).  These
 * assertions make that ABI contract a compile error to break; they encode the
 * 64-bit LP64 target the native backend assumes (D-N-008). */
_Static_assert(sizeof(LyricObjectHeader) == 2 * sizeof(void*),
               "LyricObjectHeader must stay two words: weak must fit rc's alignment padding");
_Static_assert(offsetof(LyricObjectHeader, dtor) == sizeof(void*),
               "dtor must keep its one-word offset; weak must live in rc's padding, not after dtor");

/* ── ARC intrinsics (D-N-011) ──────────────────────────────────────── */

/* malloc + abort-on-OOM.  All Lyric heap allocation goes through here. */
void* lyric_alloc(uint64_t size);

/* free() for a raw lyric_alloc buffer that is NOT an ARC object (no header).
 * Used for a protected type's runtime-sized mutex buffer (D-N-017); ARC
 * objects are freed by lyric_release, never this.  No-op on NULL. */
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
    _Atomic int32_t weak;
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
 * the object is already dead.  Static objects always upgrade.
 *
 * Safe against a concurrently-releasing strong ref: while any weak
 * reference is held the header allocation is kept alive by the weak
 * count (below), so this read of rc never touches freed memory. */
void* lyric_weak_upgrade(void* raw);

/* Increment the weak-reference count.  Called when a NativeWeak is born or
 * copied.  No-op on NULL and static objects. */
void lyric_weak_retain(void* obj);

/* Decrement the weak-reference count; frees the allocation once it reaches
 * zero.  The strong path (lyric_release) drops the implicit weak count after
 * running the destructor, so the object is freed by whichever of the last
 * strong release or the last weak release happens last.  No-op on NULL and
 * static objects. */
void lyric_weak_release(void* obj);

/* Initialise the weak count to 1 (the implicit weak held while strong refs
 * live) at object birth.  Codegen calls this right after storing rc=1 and the
 * dtor, because the weak field sits in the header's alignment padding, which
 * the generated LLVM struct type does not name. */
void lyric_weak_init(void* obj);

/* ── Collections (D-N-012) ─────────────────────────────────────────── */

/* List: dynamic array.  Element ownership is declared at construction:
 * elems_are_refs != 0 means every element is an ARC pointer that the
 * list retains on push and releases on removal / destruction; 0 means
 * elements are scalar bit-patterns stored as-is (Int/Long/Float/Bool
 * widened to 64 bits by the codegen). */
typedef struct {
    _Atomic int32_t rc;
    _Atomic int32_t weak;
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
/* Allocated slot capacity (power of two, 0 when empty).  For tests
 * asserting the tombstone-churn resize keeps capacity bounded. */
int64_t   lyric_map_cap(LyricMap* map);
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
/* Nanoseconds since the Unix epoch (CLOCK_REALTIME) — the native
 * Std.Time Instant representation (D-N-027); int64 covers years
 * ~1678..2262. */
int64_t lyric_epoch_nanos(void);
/* Monotonic nanoseconds (CLOCK_MONOTONIC). */
int64_t lyric_monotonic_nanos(void);

/* Fill buf with n cryptographically secure random bytes.  Returns 0 on
 * success, -1 on failure.  getrandom(2) on Linux, getentropy on macOS. */
int32_t lyric_secure_random(uint8_t* buf, int64_t n);

/* A fresh version-4 (random) UUID as a fresh rc=1 LyricString in the
 * canonical lowercase hyphenated 36-char form — the native Uuid
 * representation (D-N-026).  Panics if the entropy source fails. */
LyricString* lyric_uuid_v4(void);

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

/* Per-entry classification codes lyric_dir_list_typed prepends to each
 * returned name, as a single ASCII digit ('0'/'1'/'2'). */
#define LYRIC_DIRENT_OTHER 0 /* neither a regular file nor a directory */
#define LYRIC_DIRENT_DIR   1
#define LYRIC_DIRENT_REG   2

/* Single-sweep entry-name-and-kind listing (#4856): like lyric_dir_list2,
 * but also classifies every entry via `readdir`'s `d_type` in the same
 * opendir/readdir pass, eliminating the caller's separate per-entry
 * `stat()` probe.  Each returned string is a single LYRIC_DIRENT_* digit
 * ('0', '1', or '2') followed by the bare entry name (e.g. "1subdir") —
 * a single fresh rc=1 LyricList via the same return-plus-ok-flag
 * protocol as lyric_dir_list2, deliberately NOT a second ref-typed
 * out-param (a List[T] out-param initialised Lyric-side before the FFI
 * call, as the kernel layer's `nativeAddrOf` convention requires, would
 * leak that initialiser the moment this function overwrites the slot —
 * see the matching note in file_host.l).  A symlink (DT_LNK) or an
 * entry whose filesystem leaves d_type unpopulated (DT_UNKNOWN) is
 * resolved with a single following stat(2), so classification matches
 * lyric_file_exists / lyric_dir_exists exactly (both follow symlinks) —
 * only the two-probe-per-entry cost is removed, not the
 * symlink-following semantics.  *ok reports success (1/0), matching
 * lyric_dir_list2. */
LyricList* lyric_dir_list_typed(const char* path, int32_t* ok);

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

/* ── Async task scheduler (lyric_async.c) ──────────────────────────────
 *
 * Single-threaded cooperative scheduler for `async func` on the native
 * target (06-async-design.md; hot-task model — see lyric_async.c's
 * header comment for the full state machine and rc discipline).
 * `lyric_coro_resume`/`lyric_coro_destroy` are extern symbols that
 * generated IR defines as thin llvm.coro.* wrappers (CoroSplit's frame
 * fn-ptrs are `internal fastcc`, so C never calls them directly).
 */

typedef struct LyricTask {
    _Atomic int32_t rc;
    _Atomic int32_t weak;
    void (*dtor)(void*);
    void* coro_handle;        /* LLVM coro frame; destroyed by the dtor  */
    int32_t state;            /* RUNNING/SLEEPING/WAITING/READY/COMPLETE */
    int64_t result;           /* 64-bit slot, valid when COMPLETE        */
    int32_t result_is_ref;    /* task owns a ref on `result` when set    */
    int64_t wake_deadline_ns; /* monotonic deadline while SLEEPING       */
    struct LyricTask* waiters; /* tasks parked on this task's completion */
    struct LyricTask* next;    /* intrusive link (ready/sleeper/waiter)  */
} LyricTask;

/* Fresh rc=1 RUNNING task (called in the coroutine prologue). */
LyricTask* lyric_task_new(void* coro_handle);
int32_t    lyric_task_is_complete(LyricTask* t);
/* Raw result slot; a ref-typed result is a borrow (task keeps its ref). */
int64_t    lyric_task_result(LyricTask* t);
/* Store the result (ref ownership transfers in) and wake all waiters. */
void       lyric_task_complete(LyricTask* t, int64_t result, int32_t result_is_ref);
/* Park the RUNNING task on `dep` / on a timer; suspend right after. */
void       lyric_async_await(LyricTask* waiter, LyricTask* dep);
void       lyric_async_sleep(LyricTask* t, int64_t ms);
/* Drive the scheduler until `root` completes (sync-context await). */
void       lyric_task_block_on(LyricTask* root);
/* The task whose frame is executing (codegen reads it inside bodies). */
LyricTask* lyric_current_task(void);
void       lyric_set_current_task(LyricTask* t);

/* ── Process execution (lyric_process.c) ───────────────────────────── */

/* Runs `path` via fork + execvp (never a shell — no interpolation of
 * `path` or any argument), with argv built from `path` (as argv[0])
 * followed by the LyricString* elements of `args` in order.  `args`
 * may be NULL, meaning no arguments beyond argv[0].  stdout and stderr
 * are captured in full into fresh rc=1 LyricStrings.  stdin is always
 * piped (managed-twin parity): `stdin_content` (NULL or empty = no
 * content) is written interleaved with the output reads — no
 * pipe-buffer deadlock in either direction — then the write end
 * closes so the child reads EOF; content the child never reads is
 * silently dropped (EPIPE, matching the managed twin's absorbed
 * writer throw).  `timeout_ms` < 0 means no timeout; on expiry the
 * child's whole process group is SIGKILLed (the child runs in its own
 * group, so its descendants die with it — the managed twin's
 * Kill(entireProcessTree: true) semantics, D-N-025), captured output
 * is preserved, and *out_timed_out reports 1 unless the reap shows
 * the child had already exited normally (the #5107 contract).
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
                           LyricString* stdin_content, int32_t timeout_ms,
                           int32_t* out_exit_code,
                           LyricString** out_stdout,
                           LyricString** out_stderr,
                           int32_t* out_timed_out);

/* Nonblocking capture op (the async process leaf, D-N-023): the same
 * fork/execvp capture as lyric_process_run, driven by repeated
 * nonblocking pumps instead of one blocking drain, so a coroutine can
 * park itself between pumps.  Lifecycle: start -> pump until it
 * returns 1 (or kill on timeout, after which the op is done) ->
 * exit_code/stdout/stderr accessors -> free.  The handle is a raw
 * malloc'd struct, not ARC-managed.  start never returns NULL: a
 * pipe/fork failure yields a done op with spawn_failed set (an execvp
 * failure in the child is exit code 127, matching lyric_process_run).
 * The op copies `stdin_content` (NULL or empty = none) and pump
 * flushes it to the child nonblockingly before draining output,
 * closing the write end at EOF-of-content (or dropping the rest on
 * EPIPE).  The stdout/stderr accessors return fresh rc=1
 * LyricStrings.  kill sends SIGKILL to the child's whole process
 * group (D-N-025), drains what already arrived, and reaps; it returns
 * 1 when the kill terminated the child and 0 when the child had
 * already exited (its real exit status is preserved — the caller must
 * not report a timeout then, #5107). */
void* lyric_process_start(const char* path, LyricList* args, LyricString* stdin_content);
int32_t lyric_process_spawn_failed(void* op);
int32_t lyric_process_pump(void* op);
int32_t lyric_process_kill(void* op);
int32_t lyric_process_exit_code(void* op);
LyricString* lyric_process_stdout(void* op);
LyricString* lyric_process_stderr(void* op);
void lyric_process_free(void* op);

/* ── TCP sockets + TLS transport (lyric_tls.c) ─────────────────────────
 *
 * The native-target transport seam for the sans-IO `Std.HttpEngine`
 * (docs/61 §7, D128 decision 10; epic #5874 phase 5, issue #5890).  Two
 * layers: a blocking POSIX socket transport (`lyric_sock_*`) and a narrow
 * TLS seam (`lyric_tls_*`) over OpenSSL 3.x.
 *
 * OpenSSL is loaded DYNAMICALLY at runtime with dlopen/dlsym on first use
 * (see lyric_tls.c) — lyric_rt.a carries NO link-time dependency on
 * libssl/libcrypto, so a native binary that never opens a TLS connection
 * never loads OpenSSL, and the whole seam can be re-pointed at mbedTLS for
 * static/musl builds by swapping lyric_tls.c alone, without touching any
 * Lyric code (the swappable-seam intent of D128 decision 10).  Target the
 * OpenSSL 3.x ABI only.
 *
 * All handles here are RAW malloc'd resources (the lyric_process_* op
 * discipline), NOT ARC objects: a `void*` TLS context / connection is
 * released with its explicit `lyric_tls_ctx_free` / `lyric_tls_free`, and a
 * socket fd with `lyric_sock_close`.  The `_kernel_native/` Lyric twin wraps
 * each in an opaque type whose destructor calls the matching free, which is
 * where the ARC-managed-resource lifetime (docs/61 §7 item 4) is realised.
 *
 * Diagnostics: on a NULL/-1 failure the seam records a thread-local message
 * (OpenSSL's error string, or a strerror for a socket failure) retrievable
 * with `lyric_tls_last_error` — so the Lyric twin can surface a typed
 * `TcpError`/`TlsHandshakeFailed` carrying a real reason, never an opaque
 * boolean.
 */

/* ── Plain TCP sockets (POSIX; always available, no OpenSSL) ─────────── */

/* Dial a blocking TCP connection to `host`:`port`.  `host` may be an IP
 * literal or a DNS name (getaddrinfo resolves it, trying each address in
 * turn).  Returns the connected fd, or -1 on failure (last_error set). */
int32_t lyric_sock_connect(const char* host, int32_t port);

/* Bind + listen a TCP socket on `ip`:`port` (`ip` an IP literal such as
 * "127.0.0.1" / "0.0.0.0" / "::"; not a DNS name).  SO_REUSEADDR is set.
 * A `port` of 0 binds an ephemeral port (read it back with
 * `lyric_sock_local_port`).  Returns the listening fd, or -1 (last_error
 * set). */
int32_t lyric_sock_listen(const char* ip, int32_t port, int32_t backlog);

/* The local port a socket is bound to (getsockname), or -1 on failure.
 * Used to recover the kernel-assigned port after an ephemeral bind. */
int32_t lyric_sock_local_port(int32_t fd);

/* Block until a client connects to the listening `listen_fd`; returns the
 * accepted connection fd, or -1 (last_error set). */
int32_t lyric_sock_accept(int32_t listen_fd);

/* Read up to `n` bytes into `buf`, blocking until at least one arrives.
 * Returns the count read, 0 on a clean peer close (EOF), or -1 on error.
 * Retries on EINTR. */
int64_t lyric_sock_read(int32_t fd, uint8_t* buf, int64_t n);

/* Write ALL `n` bytes of `buf` (looping over partial writes, retrying on
 * EINTR).  Returns `n` on success, or -1 on error. */
int64_t lyric_sock_write(int32_t fd, const uint8_t* buf, int64_t n);

/* close(2) the fd.  Returns 0 on success, -1 on failure.  No-op on a
 * negative fd. */
int32_t lyric_sock_close(int32_t fd);

/* LyricList[Byte] bridging for `Std.TcpHost`'s `hostRead`/`hostWrite`
 * (issue #6103 item C): one 64-bit slot per byte, scalar elements
 * (D-N-015 -- slice[Byte]/List[Byte] share this representation on
 * native). `*_read_bytes` follows the file kernel's return-plus-ok-flag
 * protocol (`lyric_file_read_bytes`); `*_write_bytes` takes the already-
 * built LyricList* directly -- the Lyric-side `extern func` declares this
 * parameter as `slice[Byte]` directly (the same shape
 * `_kernel_native/file_host.l`'s `rtWriteBytes(data: List[Byte], ...)`
 * already uses), so no Lyric-side byte marshaling is needed either way. */
LyricList* lyric_sock_read_bytes(int32_t fd, int64_t max_bytes, int32_t* ok);
int64_t lyric_sock_write_bytes(int32_t fd, void* bytes_list);

/* ── TLS over OpenSSL 3.x (dlopen'd) ───────────────────────────────────
 *
 * `min_version` is 12 for TLS 1.2 (the floor) or 13 for TLS 1.3.  ALPN is
 * advertised/selected from a comma-separated wire-name list (`alpn_csv`,
 * e.g. "http/1.1" or "h2,http/1.1"); "" or NULL disables ALPN.  Every PEM
 * argument is a NUL-terminated PEM text block ("" / NULL = absent).
 */

/* 1 iff OpenSSL 3.x could be dlopen'd and every needed symbol resolved.
 * When 0, every `lyric_tls_*` constructor returns NULL with a last_error
 * naming the missing library — the Lyric twin turns that into a typed
 * "TLS unavailable" error rather than crashing. */
int32_t lyric_tls_available(void);

/* Build a CLIENT TLS context.  `ca_pem` "" / NULL uses the system default
 * verify paths (honoring SSL_CERT_FILE / SSL_CERT_DIR); a non-empty
 * `ca_pem` pins trust EXCLUSIVELY to that CA (the additive-vs-exclusive
 * distinction is a Lyric-layer concern — the seam takes exactly the trust
 * anchors it is given).  `min_version` is 12 for the TLS 1.2 floor or 13 to
 * pin TLS 1.3 (the `.withMinTlsVersion` client knob).  `insecure` != 0
 * disables certificate and hostname verification (the docs/61 §4 dual-key
 * policy override) — the ONLY way to turn verification off.  Returns a
 * context handle, or NULL (last_error set).  Free with `lyric_tls_ctx_free`. */
void* lyric_tls_client_new(const char* ca_pem, int32_t min_version, int32_t insecure);

/* Present a client certificate + key on `client_ctx` for mutual TLS.
 * `key_pem` must be an unencrypted PKCS#8 key ("BEGIN PRIVATE KEY").
 * Returns 0 on success, -1 on a load / cert-key-mismatch failure
 * (last_error set). */
int32_t lyric_tls_client_set_identity(void* client_ctx, const char* cert_pem, const char* key_pem);

/* Perform the CLIENT handshake over the already-connected `fd`.  SNI and
 * RFC 6125 hostname verification are hard-wired on from `sni_host` unless
 * the context was built `insecure`.  FAILS CLOSED: a non-insecure context
 * with an empty `sni_host` (no name to verify) is REFUSED (NULL, last_error
 * set) rather than silently downgraded to chain-only validation.  `alpn_csv`
 * advertises ALPN protocols.  Returns a connection handle on a verified
 * handshake, or NULL (last_error set); the caller still owns `fd` and closes
 * it with `lyric_sock_close`.  Free the handle with `lyric_tls_free`. */
void* lyric_tls_client_connect(void* client_ctx, int32_t fd, const char* sni_host, const char* alpn_csv);

/* Build a SERVER TLS context from an identity (`cert_pem` + `key_pem`,
 * PKCS#8).  `client_ca_pem` non-empty enables client-certificate
 * verification against that CA; `require_client_cert` != 0 makes a client
 * certificate mandatory (mutual TLS).  `alpn_csv` is the server's ordered
 * ALPN preference list.  Returns a context handle, or NULL (last_error
 * set).  Free with `lyric_tls_ctx_free`. */
void* lyric_tls_server_new(const char* cert_pem, const char* key_pem,
                           int32_t min_version, const char* client_ca_pem,
                           int32_t require_client_cert, const char* alpn_csv);

/* Perform the SERVER handshake over an accepted `fd`.  Returns a connection
 * handle on success (including a satisfied mTLS requirement), or NULL
 * (last_error set) — e.g. a required client certificate absent or not
 * chaining to `client_ca_pem`.  The caller owns `fd`.  Free with
 * `lyric_tls_free`. */
void* lyric_tls_server_accept(void* server_ctx, int32_t fd);

/* Read up to `n` decrypted bytes.  Returns the count, 0 on a clean TLS
 * close (close_notify / EOF), or -1 on error.  Transparently drives any
 * renegotiation / WANT_READ retry loop. */
int64_t lyric_tls_read(void* conn, uint8_t* buf, int64_t n);

/* Encrypt and write ALL `n` bytes.  Returns `n`, or -1 on error. */
int64_t lyric_tls_write(void* conn, const uint8_t* buf, int64_t n);

/* TLS counterparts of lyric_sock_read_bytes/lyric_sock_write_bytes above
 * (same LyricList[Byte] bridging, issue #6103 item C). */
LyricList* lyric_tls_read_bytes(void* conn, int64_t max_bytes, int32_t* ok);
int64_t lyric_tls_write_bytes(void* conn, void* bytes_list);

/* The negotiated ALPN protocol wire name into `out` (NUL-terminated,
 * truncated to `out_cap`).  Returns its length, or 0 when no ALPN protocol
 * was negotiated. */
int32_t lyric_tls_alpn(void* conn, char* out, int32_t out_cap);

/* Send a TLS close_notify (best-effort).  Does not close the fd. */
void lyric_tls_shutdown(void* conn);

/* Free a connection handle (SSL_free).  Does NOT close the underlying fd —
 * the caller closes it with `lyric_sock_close`.  No-op on NULL. */
void lyric_tls_free(void* conn);

/* Free a client/server context handle (SSL_CTX_free + owned buffers).
 * No-op on NULL. */
void lyric_tls_ctx_free(void* ctx);

/* Copy the most recent seam error message for THIS thread into `out`
 * (NUL-terminated, truncated to `out_cap`); returns its length.  Empty
 * when no error has been recorded. */
int32_t lyric_tls_last_error(char* out, int32_t out_cap);

/* ── Standalone PEM validation (no socket/handshake involved) ──────────
 *
 * `Std.TlsHost`'s native twin (issue #6103 item B) needs to validate a
 * certificate / private key PEM block at LOAD time, matching the dotnet
 * and JVM twins' eager-validation contract — but the constructors above
 * only parse PEM as a side effect of building a full TLS context. These
 * three reuse the seam's internal read_cert/read_key/use_identity parse
 * path (no OpenSSL symbols beyond what lyric_tls_server_new already
 * resolves) to answer "is this well-formed" / "does this key match this
 * cert" without allocating a socket-facing context. Each returns 1 on
 * success, 0 on failure (lyric_tls_last_error set); a cert/key mismatch
 * (including same-algorithm) is detected via SSL_CTX_check_private_key,
 * the same primitive lyric_tls_server_new itself uses. */
int32_t lyric_tls_validate_cert_pem(const char* cert_pem);
int32_t lyric_tls_validate_key_pem(const char* key_pem);
int32_t lyric_tls_validate_identity_pem(const char* cert_pem, const char* key_pem);

/* ── LyricString-returning conveniences for the `_kernel_native/` twin ──
 *
 * `lyric_tls_last_error` / `lyric_tls_alpn` above are raw fixed-buffer C
 * APIs (the seam itself has no LyricString dependency — D128 decision
 * 10's "swappable seam" requires lyric_tls.c to link standalone). These
 * two hand back a genuine owned LyricString* (rc=1, via
 * lyric_string_from_literal) so the Lyric-level `extern func` declares
 * plain `String` as its return type with no manual buffer marshaling at
 * the call site — the same convenience lyric_process_stdout/_stderr
 * already establish for a fixed-buffer C result. */
LyricString* lyric_tls_last_error_string(void);
LyricString* lyric_tls_alpn_string(void* conn);

#ifdef __cplusplus
}
#endif

#endif /* LYRIC_RT_H */
