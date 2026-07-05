/* lyric_process.c — subprocess execution with full stdout/stderr
 * capture for Std.Process (native/plan/07-stdlib-port.md).
 *
 * Always fork + execvp directly on the caller's path: no shell is ever
 * invoked, so there is no argument interpolation to worry about. argv
 * is built in the parent (malloc after fork but before exec is unsafe
 * in a multi-threaded process); the child only performs
 * async-signal-safe calls (dup2/close/execvp/_exit) between fork and
 * exec.
 */
#if defined(__linux__)
/* _GNU_SOURCE for pipe2 (O_CLOEXEC pipe creation without a race). */
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* Both capture pipes are created CLOEXEC: without the flag, a fork raced
 * by another thread (or any other subprocess spawned while this capture
 * is in flight) inherits the write ends across its own exec, holding the
 * read loop open past this child's exit.  Linux pipe2 sets the flag
 * atomically; elsewhere pipe + fcntl is the best available. */
static int pipe_cloexec(int fds[2]) {
#if defined(__linux__)
    return pipe2(fds, O_CLOEXEC);
#else
    if (pipe(fds) != 0) return -1;
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    return 0;
#endif
}

/* Growable byte buffer used to accumulate one pipe's captured output. */
typedef struct {
    uint8_t* data;
    int64_t len;
    int64_t cap;
} ProcBuf;

static void procbuf_append(ProcBuf* b, const uint8_t* chunk, int64_t n) {
    if (b->len + n > b->cap) {
        int64_t newcap = b->cap < 4096 ? 4096 : b->cap;
        while (newcap < b->len + n) {
            if (newcap > INT64_MAX / 2) /* doubling would overflow (UB) */
                lyric_panic_msg("process output exceeds capacity", "lyric_process.c", __LINE__);
            newcap *= 2;
        }
        uint8_t* nd = (uint8_t*)realloc(b->data, (size_t)newcap);
        if (!nd) lyric_panic_msg("OOM capturing process output", "lyric_process.c", __LINE__);
        b->data = nd;
        b->cap = newcap;
    }
    memcpy(b->data + b->len, chunk, (size_t)n);
    b->len += n;
}

/* Shared fork/exec: spawn `path` with `args`, wiring fresh capture pipes
 * to the child's stdout/stderr.  On success returns the child pid and
 * stores the pipe READ ends; on failure returns -1 with nothing open. */
static pid_t spawn_capture(const char* path, LyricList* args, int* out_rd, int* err_rd) {
    int out_pipe[2];
    int err_pipe[2];
    if (pipe_cloexec(out_pipe) != 0) return -1;
    if (pipe_cloexec(err_pipe) != 0) {
        close(out_pipe[0]);
        close(out_pipe[1]);
        return -1;
    }

    int64_t nargs = args ? lyric_list_len(args) : 0;
    char** argv = (char**)malloc((size_t)(nargs + 2) * sizeof(char*));
    if (!argv) {
        close(out_pipe[0]);
        close(out_pipe[1]);
        close(err_pipe[0]);
        close(err_pipe[1]);
        return -1;
    }
    argv[0] = (char*)path; /* borrowed: never freed below */
    for (int64_t i = 0; i < nargs; i++) {
        LyricString* s = (LyricString*)(intptr_t)lyric_list_get(args, i);
        argv[i + 1] = (char*)lyric_string_to_cstring(s);
    }
    argv[nargs + 1] = NULL;

    pid_t pid = fork();
    if (pid < 0) {
        for (int64_t i = 0; i < nargs; i++) lyric_cstring_free(argv[i + 1]);
        free(argv);
        close(out_pipe[0]);
        close(out_pipe[1]);
        close(err_pipe[0]);
        close(err_pipe[1]);
        return -1;
    }

    if (pid == 0) {
        /* Child: wire the pipes to stdout/stderr, then exec. Only
         * async-signal-safe calls from here to exec (or _exit). */
        close(out_pipe[0]);
        close(err_pipe[0]);
        /* If the parent had fd 1/2 closed, pipe() may have handed us those
         * very numbers: dup2 onto itself is a no-op, and an unconditional
         * close would then destroy the descriptor we just installed (or, in
         * the cross-aliased case, one installed by the other dup2).  Guard
         * each dup2, and close the source immediately so a later dup2 can
         * never be clobbered by it.  dup2 clears CLOEXEC on the new
         * descriptor; in the aliased no-dup2 branch the flag must be
         * cleared by hand or exec would close the just-wired stream. */
        if (out_pipe[1] != STDOUT_FILENO) {
            if (dup2(out_pipe[1], STDOUT_FILENO) < 0) _exit(126);
            close(out_pipe[1]);
        } else if (fcntl(out_pipe[1], F_SETFD, 0) < 0) {
            _exit(126);
        }
        if (err_pipe[1] != STDERR_FILENO) {
            if (dup2(err_pipe[1], STDERR_FILENO) < 0) _exit(126);
            close(err_pipe[1]);
        } else if (fcntl(err_pipe[1], F_SETFD, 0) < 0) {
            _exit(126);
        }
        execvp(path, argv);
        _exit(127); /* execvp failed (e.g. path not found) */
    }

    /* Parent: close the write ends and the argv cstrings (fork already
     * gave the child its own copy-on-write copy of both). */
    close(out_pipe[1]);
    close(err_pipe[1]);
    for (int64_t i = 0; i < nargs; i++) lyric_cstring_free(argv[i + 1]);
    free(argv);
    *out_rd = out_pipe[0];
    *err_rd = err_pipe[0];
    return pid;
}

int32_t lyric_process_run(const char* path, LyricList* args,
                           int32_t* out_exit_code,
                           LyricString** out_stdout,
                           LyricString** out_stderr) {
    int out_rd = -1;
    int err_rd = -1;
    pid_t pid = spawn_capture(path, args, &out_rd, &err_rd);
    if (pid < 0) return -1;

    ProcBuf outbuf;
    outbuf.data = NULL;
    outbuf.len = 0;
    outbuf.cap = 0;
    ProcBuf errbuf;
    errbuf.data = NULL;
    errbuf.len = 0;
    errbuf.cap = 0;

    struct pollfd fds[2];
    fds[0].fd = out_rd;
    fds[0].events = POLLIN;
    fds[1].fd = err_rd;
    fds[1].events = POLLIN;
    int open_fds = 2;

    uint8_t chunk[4096];
    while (open_fds > 0) {
        int ready = poll(fds, 2, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break; /* give up capturing; still reap the child below */
        }
        for (int i = 0; i < 2; i++) {
            if (fds[i].fd < 0 || fds[i].revents == 0) continue;
            ssize_t n = read(fds[i].fd, chunk, sizeof chunk);
            if (n > 0) {
                procbuf_append(i == 0 ? &outbuf : &errbuf, chunk, n);
            } else if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) {
                close(fds[i].fd);
                fds[i].fd = -1;
                open_fds--;
            }
        }
    }
    if (fds[0].fd >= 0) close(fds[0].fd);
    if (fds[1].fd >= 0) close(fds[1].fd);

    int status = 0;
    pid_t w;
    do {
        w = waitpid(pid, &status, 0);
    } while (w < 0 && errno == EINTR);

    if (w < 0) {
        free(outbuf.data);
        free(errbuf.data);
        return -1;
    }

    int32_t exit_code;
    if (WIFEXITED(status)) {
        exit_code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        exit_code = 128 + WTERMSIG(status);
    } else {
        exit_code = -1;
    }

    *out_exit_code = exit_code;
    *out_stdout = lyric_string_from_literal(outbuf.data, outbuf.len);
    *out_stderr = lyric_string_from_literal(errbuf.data, errbuf.len);
    free(outbuf.data);
    free(errbuf.data);
    return 0;
}

/* ── Nonblocking capture op (the async process leaf, D-N-023) ─────────
 *
 * The cooperative scheduler cannot block in lyric_process_run: a
 * coroutine that captures a subprocess instead drives this op through
 * repeated nonblocking pumps, parking itself between pumps via the
 * async sleep leaf (the same 1 ms poll cadence the JVM kernel twin
 * documents for its drain loop).  The op is a raw malloc'd handle —
 * Lyric holds it as NativePtr[Byte] and frees it explicitly. */
typedef struct LyricProcOp {
    pid_t pid;
    int out_fd; /* -1 once EOF */
    int err_fd;
    ProcBuf outbuf;
    ProcBuf errbuf;
    int32_t spawn_failed;
    int32_t done; /* pipes drained AND child reaped */
    int32_t exit_code;
} LyricProcOp;

static void set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

void* lyric_process_start(const char* path, LyricList* args) {
    LyricProcOp* op = (LyricProcOp*)calloc(1, sizeof(LyricProcOp));
    if (!op) lyric_panic_msg("OOM starting process op", "lyric_process.c", __LINE__);
    op->out_fd = -1;
    op->err_fd = -1;
    op->exit_code = -1;
    pid_t pid = spawn_capture(path, args, &op->out_fd, &op->err_fd);
    if (pid < 0) {
        op->spawn_failed = 1;
        op->done = 1;
        return op;
    }
    op->pid = pid;
    set_nonblock(op->out_fd);
    set_nonblock(op->err_fd);
    return op;
}

int32_t lyric_process_spawn_failed(void* raw) {
    return ((LyricProcOp*)raw)->spawn_failed;
}

/* Drain whatever is available from one pipe without blocking; closes
 * the fd (and marks it -1) on EOF or a hard error. */
static void pump_fd(int* fd, ProcBuf* buf) {
    if (*fd < 0) return;
    uint8_t chunk[4096];
    for (;;) {
        ssize_t n = read(*fd, chunk, sizeof chunk);
        if (n > 0) {
            procbuf_append(buf, chunk, n);
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (n < 0 && errno == EINTR) continue;
        close(*fd); /* EOF or hard error */
        *fd = -1;
        return;
    }
}

static int32_t status_to_exit_code(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

/* One nonblocking step: drain available output; once both pipes hit
 * EOF, try a WNOHANG reap.  Returns 1 when the op is fully done. */
int32_t lyric_process_pump(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    if (op->done) return 1;
    pump_fd(&op->out_fd, &op->outbuf);
    pump_fd(&op->err_fd, &op->errbuf);
    if (op->out_fd < 0 && op->err_fd < 0) {
        int status = 0;
        pid_t w = waitpid(op->pid, &status, WNOHANG);
        if (w == op->pid) {
            op->exit_code = status_to_exit_code(status);
            op->done = 1;
        } else if (w < 0 && errno != EINTR) {
            op->exit_code = -1; /* already reaped elsewhere — should not happen */
            op->done = 1;
        }
    }
    return op->done;
}

/* Timeout path: SIGKILL the child, drain what already arrived, close
 * the pipes, and reap (blocking — the child is dead, the reap is
 * immediate).  After this the op is done. */
void lyric_process_kill(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    if (op->done) return;
    kill(op->pid, SIGKILL);
    pump_fd(&op->out_fd, &op->outbuf);
    pump_fd(&op->err_fd, &op->errbuf);
    if (op->out_fd >= 0) {
        close(op->out_fd);
        op->out_fd = -1;
    }
    if (op->err_fd >= 0) {
        close(op->err_fd);
        op->err_fd = -1;
    }
    int status = 0;
    pid_t w;
    do {
        w = waitpid(op->pid, &status, 0);
    } while (w < 0 && errno == EINTR);
    op->exit_code = w == op->pid ? status_to_exit_code(status) : -1;
    op->done = 1;
}

int32_t lyric_process_exit_code(void* raw) {
    return ((LyricProcOp*)raw)->exit_code;
}

LyricString* lyric_process_stdout(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    return lyric_string_from_literal(op->outbuf.data, op->outbuf.len);
}

LyricString* lyric_process_stderr(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    return lyric_string_from_literal(op->errbuf.data, op->errbuf.len);
}

void lyric_process_free(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    if (op->out_fd >= 0) close(op->out_fd);
    if (op->err_fd >= 0) close(op->err_fd);
    free(op->outbuf.data);
    free(op->errbuf.data);
    free(op);
}
