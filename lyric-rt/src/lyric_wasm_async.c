/* lyric_wasm_async.c — the scheduler entry the `--shape module` glue uses to
 * drive async exports (docs/35 §11).  Kept apart from lyric_wasm.c so a module
 * with no async export never pulls the scheduler (and its coroutine symbols)
 * into the link.
 */
#include "lyric_rt.h"

#include <stdint.h>
#include <string.h>

/* Drive the cooperative scheduler for an async export (docs/35 §11): runs every
 * ready task and returns the milliseconds until the next timer fires (rounded
 * up, 0 when one is due now), -2 when the only thing left is an operation the
 * host has yet to finish, or -1 when no task can ever make progress.  The
 * glue calls it from a host timer and resolves a call's promise once its task
 * is complete (lyric_task_is_complete / lyric_task_result). */
int64_t lyric_wasm_poll(void) {
    int64_t ns = lyric_sched_poll();
    if (ns <= 0) {
        return ns;
    }
    return (ns + 999999) / 1000000;
}

/* Host-finished operations (docs/35 §11): a host import that returns a `Task[T]`
 * is given a pending task by the glue, which finishes it from the promise's
 * settlement.  The task is created with two refs, one for the importing code
 * (the glue returns it from the import) and one the host spends finishing it.
 * A String result is a Lyric String the glue created (rc 1); the task takes it. */
void* lyric_wasm_host_task_new(void) {
    return lyric_host_task_new();
}

void lyric_wasm_host_finish_i32(void* task, int32_t v) {
    lyric_host_task_finish((LyricTask*)task, (int64_t)v, 0);
}

void lyric_wasm_host_finish_i64(void* task, int64_t v) {
    lyric_host_task_finish((LyricTask*)task, v, 0);
}

void lyric_wasm_host_finish_f32(void* task, float v) {
    uint32_t b;
    memcpy(&b, &v, sizeof b);
    lyric_host_task_finish((LyricTask*)task, (int64_t)b, 0);
}

void lyric_wasm_host_finish_f64(void* task, double v) {
    int64_t b;
    memcpy(&b, &v, sizeof b);
    lyric_host_task_finish((LyricTask*)task, b, 0);
}

void lyric_wasm_host_finish_string(void* task, void* s) {
    lyric_host_task_finish((LyricTask*)task, (int64_t)(intptr_t)s, 1);
}

void lyric_wasm_host_fail(void* task, void* message) {
    lyric_host_task_fail((LyricTask*)task, (LyricString*)message);
}
