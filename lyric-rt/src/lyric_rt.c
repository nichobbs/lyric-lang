/* lyric_rt.c — ARC core: alloc, retain, release, panic.
 * Spec: native/plan/04-arc-design.md.
 */
#include "lyric_rt.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

void* lyric_alloc(uint64_t size) {
    void* p = malloc((size_t)size);
    if (!p) {
        fputs("lyric: out of memory\n", stderr);
        abort();
    }
    return p;
}

/* Free a raw buffer obtained from lyric_alloc that is NOT an ARC object with a
 * header (e.g. a protected type's runtime-sized pthread_mutex_t buffer, which
 * is pointed to by the object rather than embedded — see D-N-017). ARC objects
 * are freed by lyric_release, never this. */
void lyric_free(void* p) {
    free(p);
}

void lyric_retain(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    int32_t current = atomic_load_explicit(&h->rc, memory_order_relaxed);
    if (current == INT32_MAX) return; /* static object */
    /* relaxed suffices: the caller already holds a strong reference, so
     * the object is alive and no ordering with other memory is needed. */
    atomic_fetch_add_explicit(&h->rc, 1, memory_order_relaxed);
}

void lyric_release(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    int32_t current = atomic_load_explicit(&h->rc, memory_order_relaxed);
    if (current == INT32_MAX) return; /* static object */
    if (atomic_fetch_sub_explicit(&h->rc, 1, memory_order_release) == 1) {
        /* The acquire fence pairs with the release decrement so every
         * write made by other threads (while they held their strong
         * refs) is visible to the destructor. */
        atomic_thread_fence(memory_order_acquire);
        if (h->dtor) h->dtor(obj);
        free(obj);
    }
}

_Noreturn void lyric_panic_msg(const char* msg, const char* file, int32_t line) {
    fprintf(stderr, "lyric panic at %s:%d: %s\n",
            file ? file : "<unknown>", line, msg ? msg : "");
    fflush(stderr);
    abort();
}
