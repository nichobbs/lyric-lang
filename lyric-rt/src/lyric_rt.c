/* lyric_rt.c — ARC core: alloc, retain, release, panic.
 * Spec: native/plan/04-arc-design.md.
 */
#include "lyric_rt.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

/* Weakly-declared rather than pulled in via <sanitizer/lsan_interface.h>
 * behind a __SANITIZE_ADDRESS__/__has_feature(address_sanitizer) compile-
 * time guard on THIS translation unit's own flags: lyric_rt.a is built
 * ONCE (`make -C lyric-rt`, no -fsanitize=address) and then statically
 * linked into every --target native binary, ASan-instrumented or not, so a
 * compile-time check here can never see whether the DOWNSTREAM final link
 * will actually pull in the ASan/LeakSanitizer runtime -- confirmed by
 * direct repro: that compile-time guard made lyric_lsan_ignore_leak a
 * permanent no-op in every real ASan self-test binary, since lyric_rt.o
 * itself is never compiled with the sanitizer flag. A weak declaration
 * resolves to the real LSan function only when the FINAL link actually
 * adds -fsanitize=address (pulling in the sanitizer runtime that defines
 * it); otherwise the symbol resolves to NULL, so this stays a safe no-op
 * in a plain (non-ASan) native build without needing to link against the
 * sanitizer runtime at all. */
extern void __lsan_ignore_object(const void* p) __attribute__((weak));

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
 * are freed by lyric_release, never this.  No-op on NULL (guarded explicitly
 * for consistency with lyric_retain/lyric_release, though free(NULL) is a
 * C-standard no-op). */
void lyric_free(void* p) {
    if (!p) return;
    free(p);
}

/* Mark a raw lyric_alloc/malloc'd block as a deliberate, provably-safe
 * "leak" LeakSanitizer should not report (issue #6802): used exactly once,
 * by _kernel_native/http_server.l's stopListener, for the queue mutex/
 * semaphore buffer when a caller-owned puller thread is still genuinely
 * parked inside a blocking wait on it. Freeing in that situation would be a
 * real use-after-free the instant that thread resumed; NOT freeing at all
 * is safe (that thread can never receive a legitimate item again once the
 * listener has fully torn down, so it stays parked for the rest of the
 * process's life without ever touching invalid memory) but is still, from
 * LeakSanitizer's pointer-reachability analysis, indistinguishable from an
 * accidental leak -- confirmed by direct repro, not assumed: a genuinely
 * still-blocked thread's own stack frame does NOT reliably keep this
 * project's condvar-backed semaphore's backing pointer in a form LSan's
 * scanner recognizes as reachable, so an unconditionally-leaked buffer
 * here fails the ASan+LSan build on the very code path meant to fix a
 * memory-safety bug. This is the sanctioned LeakSanitizer API for
 * exactly this situation -- a small, bounded, disclosed, PROVEN-safe
 * retention, not a suppression of an actual bug -- not a general-purpose
 * "hide a leak" escape hatch, and lyric-rt has exactly one caller of it.
 * A no-op in a non-ASan build (the interface only exists when linked in). */
void lyric_lsan_ignore_leak(void* p) {
    if (p && __lsan_ignore_object) {
        __lsan_ignore_object(p);
    }
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
        /* Strong count hit zero: the destructor has run and the payload is
         * dead, but a NativeWeak may still be observing the header.  Drop the
         * implicit weak count rather than freeing here; lyric_weak_release
         * performs the free once the last weak reference is also gone (which,
         * absent any live NativeWeak, is right now). */
        lyric_weak_release(obj);
    }
}

/* Reinterpret a raw pointer as its bit-identical 64-bit integer value and
 * back — pure `ptrtoint`/`inttoptr`, no dereference. Lets a `.l` file
 * store a pointer it does not otherwise own the layout of (e.g. a
 * retained closure's environment pointer) as the `Long` this codebase's
 * own "Long-as-pointer-handle" idiom already uses for every other
 * long-lived native handle (`ServerQueue.mutex`, `Conn.tlsConnHandle`,
 * etc., all documented in `_kernel_native/tcp_host.l`'s module header):
 * the N0100 mode-checker rule rejects a `NativePtr[T]` record/union
 * field unconditionally ("heap storage outlives any frame"), so a
 * pointer that must survive past the frame that produced it has nowhere
 * else to live. */
int64_t lyric_ptr_to_long(void* p) {
    return (int64_t)(intptr_t)p;
}

void* lyric_long_to_ptr(int64_t v) {
    return (void*)(intptr_t)v;
}

_Noreturn void lyric_panic_msg(const char* msg, const char* file, int32_t line) {
    fprintf(stderr, "lyric panic at %s:%d: %s\n",
            file ? file : "<unknown>", line, msg ? msg : "");
    fflush(stderr);
    abort();
}
