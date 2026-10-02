/* lyric_wasm.c — the ABI the generated JS glue uses to move values across a
 * `--shape module` boundary (docs/35 §4, phase W3).  Plain C-ABI functions the
 * link step exports by name; none of them is referenced by Lyric code.
 *
 * Ownership follows native/plan/04-arc-design.md: arguments are borrowed, a
 * returned heap value is owned by the caller.  The glue therefore creates each
 * String argument with lyric_wasm_string_new, passes it, and releases it
 * afterwards, and releases every String a call returns once it has copied the
 * bytes out.
 */
#include "lyric_rt.h"

#include <stdint.h>
#include <stdlib.h>

/* Bumped when the exported helper set changes incompatibly; the glue refuses a
 * module whose version differs from the one it was generated for. */
int32_t lyric_wasm_abi_version(void) {
    return 2;
}

/* A scratch buffer in linear memory for the glue to copy bytes into or out of
 * (UTF-8 text, argv).  Plain malloc memory, not an ARC object. */
void* lyric_wasm_alloc(int32_t n) {
    void* p = malloc(n > 0 ? (size_t)n : 1u);
    if (!p) {
        lyric_panic_msg("lyric_wasm_alloc: out of memory", "lyric_wasm.c", __LINE__);
    }
    return p;
}

void lyric_wasm_free(void* p) {
    free(p);
}

/* Copies `len` UTF-8 bytes into a new Lyric String (rc 1, owned by the caller). */
void* lyric_wasm_string_new(const uint8_t* data, int32_t len) {
    return lyric_string_from_literal(data, (int64_t)len);
}

int32_t lyric_wasm_string_len(void* s) {
    return (int32_t)lyric_string_len((LyricString*)s);
}

const uint8_t* lyric_wasm_string_data(void* s) {
    return LYRIC_STRING_DATA(s);
}

void lyric_wasm_retain(void* obj) {
    lyric_retain(obj);
}

void lyric_wasm_release(void* obj) {
    lyric_release(obj);
}

/* Drive the cooperative scheduler for an async export (docs/35 §11): runs every
 * ready task and returns the milliseconds until the next timer fires (rounded
 * up, 0 when one is due now), or -1 when no task can ever make progress.  The
 * glue calls it from a host timer and resolves a call's promise once its task
 * is complete (lyric_task_is_complete / lyric_task_result). */
int64_t lyric_wasm_poll(void) {
    int64_t ns = lyric_sched_poll();
    if (ns <= 0) {
        return ns;
    }
    return (ns + 999999) / 1000000;
}
