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
        while (newcap < b->len + n) newcap *= 2;
        uint8_t* nd = (uint8_t*)realloc(b->data, (size_t)newcap);
        if (!nd) lyric_panic_msg("OOM capturing process output", "lyric_process.c", __LINE__);
        b->data = nd;
        b->cap = newcap;
    }
    memcpy(b->data + b->len, chunk, (size_t)n);
    b->len += n;
}

int32_t lyric_process_run(const char* path, LyricList* args,
                           int32_t* out_exit_code,
                           LyricString** out_stdout,
                           LyricString** out_stderr) {
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

    ProcBuf outbuf;
    outbuf.data = NULL;
    outbuf.len = 0;
    outbuf.cap = 0;
    ProcBuf errbuf;
    errbuf.data = NULL;
    errbuf.len = 0;
    errbuf.cap = 0;

    struct pollfd fds[2];
    fds[0].fd = out_pipe[0];
    fds[0].events = POLLIN;
    fds[1].fd = err_pipe[0];
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
