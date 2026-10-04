/* lyric_process_unsupported.c — the lyric_process_* surface for targets with
 * no child processes (wasm32-wasi, docs/35 §5.3).  It replaces
 * lyric_process.c in that build so every `_kernel_native/process_*` extern
 * still resolves, and each entry point reports the same failure its real
 * counterpart reports when a child cannot be started (the documented
 * "spawn failed" contract), never an undefined symbol at link time.
 */
#include "lyric_rt.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* ENOSYS is "function not implemented": the message the Lyric side surfaces
 * through lyric_process_errno_message. */
static int32_t last_spawn_errno = ENOSYS;

typedef struct {
    int32_t spawn_failed;
} LyricProcOp;

int32_t lyric_process_run(const char* path, LyricList* args,
                          LyricString* stdin_content, int32_t timeout_ms,
                          int32_t* out_exit_code, LyricString** out_stdout,
                          LyricString** out_stderr, int32_t* out_timed_out) {
    (void)path; (void)args; (void)stdin_content; (void)timeout_ms;
    (void)out_exit_code; (void)out_stdout; (void)out_stderr; (void)out_timed_out;
    last_spawn_errno = ENOSYS;
    return -1;
}

int32_t lyric_process_run_inherited(const char* path, LyricList* args,
                                    int32_t* out_exit_code) {
    (void)path; (void)args; (void)out_exit_code;
    last_spawn_errno = ENOSYS;
    return -1;
}

int32_t lyric_process_last_spawn_errno(void) {
    return last_spawn_errno;
}

LyricString* lyric_process_errno_message(int32_t e) {
    const char* m = strerror((int)e);
    return lyric_string_from_literal((const uint8_t*)m, (int64_t)strlen(m));
}

/* start never returns NULL: a spawn failure is a done op with spawn_failed
 * set, exactly as the real implementation reports a pipe/fork failure. */
void* lyric_process_start(const char* path, LyricList* args, LyricString* stdin_content) {
    (void)path; (void)args; (void)stdin_content;
    LyricProcOp* op = (LyricProcOp*)calloc(1, sizeof(LyricProcOp));
    if (!op) lyric_panic_msg("OOM starting process op", "lyric_process_unsupported.c", __LINE__);
    op->spawn_failed = 1;
    last_spawn_errno = ENOSYS;
    return op;
}

int32_t lyric_process_spawn_failed(void* op) {
    return ((LyricProcOp*)op)->spawn_failed;
}

int32_t lyric_process_pump(void* op) {
    (void)op;
    return 1; /* done */
}

int32_t lyric_process_kill(void* op) {
    (void)op;
    return 0; /* nothing to terminate */
}

int32_t lyric_process_exit_code(void* op) {
    (void)op;
    return -1;
}

LyricString* lyric_process_stdout(void* op) {
    (void)op;
    return lyric_string_from_literal((const uint8_t*)"", 0);
}

LyricString* lyric_process_stderr(void* op) {
    (void)op;
    return lyric_string_from_literal((const uint8_t*)"", 0);
}

void lyric_process_free(void* op) {
    free(op);
}

/* No handle ever exists (spawn returns NULL), so the remaining entry points
 * only need defined answers for a caller that passes NULL anyway. */
void* lyric_process_piped_spawn(const char* path, LyricList* args) {
    (void)path; (void)args;
    last_spawn_errno = ENOSYS;
    return NULL;
}

int32_t lyric_process_piped_read_line(void* p, LyricString** out_line) {
    (void)p; (void)out_line;
    return 0; /* no more lines */
}

int32_t lyric_process_piped_read_line_within(void* p, LyricString** out_line, int32_t timeout_ms) {
    (void)p; (void)out_line; (void)timeout_ms;
    return 0;
}

int32_t lyric_process_piped_write_line(void* p, LyricString* line) {
    (void)p; (void)line;
    return -1;
}

int32_t lyric_process_piped_is_alive(void* p) {
    (void)p;
    return 0;
}

int32_t lyric_process_piped_kill(void* p) {
    (void)p;
    return 0;
}

int32_t lyric_process_piped_wait_exit(void* p, int32_t timeout_ms) {
    (void)p; (void)timeout_ms;
    return 1;
}

int32_t lyric_process_piped_exit_code(void* p) {
    (void)p;
    return -1;
}

int32_t lyric_process_piped_close_stdin(void* p) {
    (void)p;
    return 0;
}

void lyric_process_piped_close(void* p) {
    (void)p;
}

/* wasi-libc has no threads: report the failure pthread_create reports when it
 * cannot start one, and treat any handle as already gone on join. */
int32_t lyric_thread_create(int64_t* tid, void* (*start)(void*), void* arg) {
    (void)tid; (void)start; (void)arg;
    return EAGAIN;
}

int32_t lyric_thread_join(int64_t tid, void** retval) {
    (void)tid; (void)retval;
    return ESRCH;
}

int32_t lyric_thread_spawn_detached(void* (*start)(void*), void* arg) {
    (void)start; (void)arg;
    return EAGAIN;
}
