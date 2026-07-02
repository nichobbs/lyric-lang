/* lyric_weak.c — NativeWeak[T] upgrade (04-arc-design.md §NativeWeak).
 *
 * A weak reference stores the raw object pointer without incrementing
 * rc.  upgrade() must atomically transition "still alive" into "holds a
 * strong reference" — a plain load-check-then-retain would race with a
 * releasing thread, so a CAS loop increments rc only if it is still the
 * value we observed (and > 0).
 */
#include "lyric_rt.h"

#include <limits.h>

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
