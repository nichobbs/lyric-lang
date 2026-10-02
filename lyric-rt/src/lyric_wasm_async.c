/* lyric_wasm_async.c — the scheduler entry the `--shape module` glue uses to
 * drive async exports (docs/35 §11).  Kept apart from lyric_wasm.c so a module
 * with no async export never pulls the scheduler (and its coroutine symbols)
 * into the link.
 */
#include "lyric_rt.h"

#include <stdint.h>

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
