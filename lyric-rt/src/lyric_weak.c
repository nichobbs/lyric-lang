/* lyric_weak.c — NativeWeak[T] weak-reference counting and upgrade
 * (04-arc-design.md §NativeWeak).
 *
 * A weak reference does not keep the object's payload alive, but it DOES
 * keep the header allocation alive: the header carries a second count
 * (`weak`) that tracks the number of live weak references plus one while
 * any strong reference exists.  The allocation is freed only when `weak`
 * reaches zero, so upgrade()'s read of `rc` never touches freed memory
 * (issue #5504 — previously the header had no weak count and upgrade()
 * read through a dangling/reused pointer).
 *
 * upgrade() must atomically transition "still alive" into "holds a strong
 * reference" — a plain load-check-then-retain would race with a releasing
 * thread, so a CAS loop increments rc only if it is still the value we
 * observed (and > 0).
 */
#include "lyric_rt.h"

#include <limits.h>
#include <stdlib.h>

void lyric_weak_retain(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    if (atomic_load_explicit(&h->rc, memory_order_relaxed) == INT32_MAX) return;
    /* relaxed: the caller already holds a weak (or strong) reference, so the
     * header is alive and no ordering with other memory is needed. */
    atomic_fetch_add_explicit(&h->weak, 1, memory_order_relaxed);
}

void lyric_weak_release(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    if (atomic_load_explicit(&h->rc, memory_order_relaxed) == INT32_MAX) return;
    if (atomic_fetch_sub_explicit(&h->weak, 1, memory_order_release) == 1) {
        /* The acquire fence pairs with the release decrement so the destructor's
         * writes (run by the last strong release before it dropped the implicit
         * weak) are complete before the allocation is handed back to malloc. */
        atomic_thread_fence(memory_order_acquire);
        free(obj);
    }
}

void lyric_weak_init(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    atomic_store_explicit(&h->weak, 1, memory_order_relaxed);
}

void* lyric_weak_upgrade(void* raw) {
    if (!raw) return (void*)0;
    LyricObjectHeader* h = (LyricObjectHeader*)raw;
    int32_t old_rc = atomic_load_explicit(&h->rc, memory_order_seq_cst);
    for (;;) {
        if (old_rc == INT32_MAX) return raw; /* static object: always alive */
        if (old_rc <= 0) return (void*)0;    /* already dead (or dying)     */
        if (atomic_compare_exchange_weak_explicit(&h->rc, &old_rc, old_rc + 1,
                                                  memory_order_seq_cst,
                                                  memory_order_seq_cst)) {
            return raw; /* caller now holds a strong reference */
        }
        /* old_rc was refreshed by the failed CAS; loop and re-check. */
    }
}
