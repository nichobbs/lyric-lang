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
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
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
 * to the child's stdin/stdout/stderr.  stdin is ALWAYS piped — matching
 * the managed twin, which always redirects it: the parent writes the
 * (possibly empty) content and closes, so the child reads EOF instead
 * of inheriting the parent's terminal.  On success returns the child
 * pid and stores the parent-side ends (stdout/stderr READ, stdin
 * WRITE); on failure returns -1 with nothing open. */
static pid_t spawn_capture(const char* path, LyricList* args, int* out_rd, int* err_rd, int* in_wr) {
    int out_pipe[2];
    int err_pipe[2];
    int in_pipe[2];
    if (pipe_cloexec(out_pipe) != 0) return -1;
    if (pipe_cloexec(err_pipe) != 0) {
        close(out_pipe[0]);
        close(out_pipe[1]);
        return -1;
    }
    if (pipe_cloexec(in_pipe) != 0) {
        close(out_pipe[0]);
        close(out_pipe[1]);
        close(err_pipe[0]);
        close(err_pipe[1]);
        return -1;
    }
#if defined(__APPLE__)
    /* Writes to the stdin pipe after the child exits must not raise
     * SIGPIPE; macOS has a per-fd opt-out (Linux handles it around each
     * write in stdin_write instead — see there).  stdin_write's macOS
     * arm relies on this flag being set, so a failure here would turn a
     * routine child-exits-early EPIPE into process death — treat it as
     * the invariant violation it is, like set_nonblock (#5110, #5172). */
    if (fcntl(in_pipe[1], F_SETNOSIGPIPE, 1) < 0) {
        lyric_panic_msg("cannot set F_SETNOSIGPIPE on the stdin pipe", "lyric_process.c", __LINE__);
    }
#endif

    int64_t nargs = args ? lyric_list_len(args) : 0;
    char** argv = (char**)malloc((size_t)(nargs + 2) * sizeof(char*));
    if (!argv) {
        close(out_pipe[0]);
        close(out_pipe[1]);
        close(err_pipe[0]);
        close(err_pipe[1]);
        close(in_pipe[0]);
        close(in_pipe[1]);
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
        close(in_pipe[0]);
        close(in_pipe[1]);
        return -1;
    }

    if (pid == 0) {
        /* Child: own process group first, then wire the pipes onto fds
         * 0/1/2 and exec.  Only async-signal-safe calls from here to
         * exec (or _exit).
         *
         * The new group is what lets a deadline kill take the child's
         * whole descendant tree with one kill(-pid) — the managed
         * twin's Kill(entireProcessTree: true) semantics, without the
         * walk-the-tree races (D-N-025).  A fresh fork child cannot be
         * a session leader, so setpgid(0, 0) cannot legitimately fail.
         *
         * Trade-off, documented in D-N-025: a group-isolated child no
         * longer receives terminal-generated signals (Ctrl+C) with the
         * parent; parent death still closes the pipes, so the child
         * sees EOF/EPIPE instead.
         *
         * If the parent had any of fds 0/1/2 closed, pipe() may have
         * handed the pipes those very numbers, so a source fd can
         * collide with a dup2 target.  Rather than case-analyse the
         * aliasing (the pre-stdin version of this block did, for two
         * targets), first lift every source above the target range
         * with F_DUPFD: afterwards all sources are >= 3 and the three
         * dup2 calls cannot clobber one another.  dup2 leaves CLOEXEC
         * clear on the target, so 0/1/2 survive the exec; the lifted
         * sources are closed explicitly. */
        if (setpgid(0, 0) < 0) _exit(126);
        close(out_pipe[0]);
        close(err_pipe[0]);
        close(in_pipe[1]);
        int in_src = in_pipe[0];
        int out_src = out_pipe[1];
        int err_src = err_pipe[1];
        if (in_src < 3) {
            in_src = fcntl(in_src, F_DUPFD, 3);
            if (in_src < 0) _exit(126);
            close(in_pipe[0]);
        }
        if (out_src < 3) {
            out_src = fcntl(out_src, F_DUPFD, 3);
            if (out_src < 0) _exit(126);
            close(out_pipe[1]);
        }
        if (err_src < 3) {
            err_src = fcntl(err_src, F_DUPFD, 3);
            if (err_src < 0) _exit(126);
            close(err_pipe[1]);
        }
        if (dup2(in_src, STDIN_FILENO) < 0) _exit(126);
        if (dup2(out_src, STDOUT_FILENO) < 0) _exit(126);
        if (dup2(err_src, STDERR_FILENO) < 0) _exit(126);
        close(in_src);
        close(out_src);
        close(err_src);
        execvp(path, argv);
        _exit(127); /* execvp failed (e.g. path not found) */
    }

    /* Parent: mirror the child's setpgid so a kill(-pid) issued before
     * the child has run cannot miss the group (the standard double-
     * setpgid idiom).  EACCES just means the child already exec'd —
     * its own setpgid ran first — so the result is ignored. */
    (void)setpgid(pid, pid);
    /* Close the child-side ends and the argv cstrings (fork already
     * gave the child its own copy-on-write copy of both). */
    close(out_pipe[1]);
    close(err_pipe[1]);
    close(in_pipe[0]);
    for (int64_t i = 0; i < nargs; i++) lyric_cstring_free(argv[i + 1]);
    free(argv);
    /* Success path ONLY: every failure path above returns -1 before
     * reaching these writes, so callers' -1 sentinels survive a failed
     * spawn and their close/free paths stay no-ops. */
    *out_rd = out_pipe[0];
    *err_rd = err_pipe[0];
    *in_wr = in_pipe[1];
    return pid;
}

/* Write to the child's stdin pipe without the process dying on
 * SIGPIPE when the child has already closed its end (or exited): on
 * macOS the fd carries F_SETNOSIGPIPE (set at creation); on Linux the
 * signal is blocked for the duration and a SIGPIPE our own write
 * generated is consumed before unblocking (skipped when the caller
 * already had it blocked — then it stays pending for them).  Returns
 * the write(2) result with errno preserved (EPIPE = child gone). */
static ssize_t stdin_write(int fd, const uint8_t* data, size_t len) {
#if defined(__APPLE__)
    return write(fd, data, len);
#else
    sigset_t pipe_set;
    sigset_t old_set;
    sigemptyset(&pipe_set);
    sigaddset(&pipe_set, SIGPIPE);
    /* Like the fcntl invariant checks above (#5110, #5172): a silent
     * pthread_sigmask failure would let a dead child's EPIPE arrive as
     * a process-killing SIGPIPE — the exact failure this helper
     * exists to prevent — so treat it as unrecoverable (#5178). */
    if (pthread_sigmask(SIG_BLOCK, &pipe_set, &old_set) != 0) {
        lyric_panic_msg("cannot block SIGPIPE around a stdin write", "lyric_process.c", __LINE__);
    }
    ssize_t n = write(fd, data, len);
    int saved = errno;
    if (n < 0 && saved == EPIPE && !sigismember(&old_set, SIGPIPE)) {
        struct timespec zero = {0, 0};
        sigtimedwait(&pipe_set, NULL, &zero);
    }
    if (pthread_sigmask(SIG_SETMASK, &old_set, NULL) != 0) {
        lyric_panic_msg("cannot restore the signal mask after a stdin write", "lyric_process.c", __LINE__);
    }
    errno = saved;
    return n;
#endif
}

/* A blocking read end would let pump_fd stall the whole scheduler
 * thread; on a fresh pipe fd fcntl cannot realistically fail, so treat
 * failure as the invariant violation it is rather than degrading to
 * blocking reads silently (#5110). */
static void set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        lyric_panic_msg("cannot make a capture pipe nonblocking", "lyric_process.c", __LINE__);
    }
}

/* Blocking capture with stdin content and a kill-on-deadline timeout
 * (#4752).  stdin writes interleave with stdout/stderr reads in one
 * poll loop, so a child that fills an output pipe while the parent is
 * mid-write cannot deadlock either side.  timeout_ms < 0 means no
 * timeout; on expiry the child's whole process group is SIGKILLed
 * (D-N-025), already-captured output is preserved, and *out_timed_out
 * reports 1 UNLESS the reap shows the child had already exited
 * normally (the same #5107 contract as the async op's kill). */
int32_t lyric_process_run(const char* path, LyricList* args,
                           LyricString* stdin_content, int32_t timeout_ms,
                           int32_t* out_exit_code,
                           LyricString** out_stdout,
                           LyricString** out_stderr,
                           int32_t* out_timed_out) {
    int out_rd = -1;
    int err_rd = -1;
    int in_wr = -1;
    pid_t pid = spawn_capture(path, args, &out_rd, &err_rd, &in_wr);
    if (pid < 0) return -1;

    const uint8_t* in_data = stdin_content ? LYRIC_STRING_DATA(stdin_content) : NULL;
    int64_t in_len = stdin_content ? lyric_string_len(stdin_content) : 0;
    int64_t in_off = 0;
    if (in_len == 0) {
        close(in_wr);
        in_wr = -1;
    } else {
        /* POSIX: a blocking pipe write of more than PIPE_BUF bytes blocks
         * until the FULL count is written, so one large stdin_write here
         * would deadlock against the child's full stdout pipe.  Nonblocking
         * partial writes keep the poll loop interleaving writes and reads. */
        set_nonblock(in_wr);
    }

    int64_t deadline_ns = timeout_ms >= 0 ? lyric_monotonic_nanos() + (int64_t)timeout_ms * 1000000 : -1;
    int killed = 0;
    int64_t kill_ns = 0;
    int timed_out = 0;

    ProcBuf outbuf;
    outbuf.data = NULL;
    outbuf.len = 0;
    outbuf.cap = 0;
    ProcBuf errbuf;
    errbuf.data = NULL;
    errbuf.len = 0;
    errbuf.cap = 0;

    struct pollfd fds[3];
    fds[0].fd = out_rd;
    fds[0].events = POLLIN;
    fds[1].fd = err_rd;
    fds[1].events = POLLIN;
    fds[2].fd = in_wr;
    fds[2].events = POLLOUT;

    uint8_t chunk[4096];
    while (fds[0].fd >= 0 || fds[1].fd >= 0) {
        /* Before the deadline: wait until it.  After a kill: 100 ms
         * waits under a 2 s total drain budget, so a grandchild holding
         * an inherited pipe write end past the (dead) child cannot
         * stall the EOF wait — whether it sits idle (one empty window
         * ends the drain) or keeps writing (the budget does, #5176).
         * Either way the drain gives up and force-closes below. */
        int wait_ms = -1;
        if (killed) {
            if (lyric_monotonic_nanos() - kill_ns > 2000000000LL) {
                break; /* post-kill drain budget exhausted; force-close below */
            }
            wait_ms = 100;
        } else if (deadline_ns >= 0) {
            int64_t left_ns = deadline_ns - lyric_monotonic_nanos();
            if (left_ns <= 0) {
                wait_ms = 0;
            } else {
                /* Clamp: a timeout_ms near INT32_MAX yields more
                 * milliseconds than poll()'s int timeout holds (#5174);
                 * at the cap poll simply wakes and re-arms. */
                int64_t left_ms = left_ns / 1000000 + 1;
                wait_ms = left_ms > INT32_MAX ? INT32_MAX : (int)left_ms;
            }
        }
        int ready = poll(fds, 3, wait_ms);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break; /* give up capturing; still reap the child below */
        }
        if (ready == 0) {
            if (killed) {
                break; /* post-kill drain exhausted; force-close below */
            }
            /* Deadline expired: kill the child's whole process group
             * (D-N-025 — spawn_capture put it in its own), stop
             * feeding stdin, and keep draining until the output pipes
             * report EOF.  The direct-pid fallback covers the
             * cannot-happen case of both setpgid calls failing. */
            if (kill(-pid, SIGKILL) != 0) {
                kill(pid, SIGKILL);
            }
            killed = 1;
            kill_ns = lyric_monotonic_nanos();
            if (fds[2].fd >= 0) {
                close(fds[2].fd);
                fds[2].fd = -1;
            }
            continue;
        }
        for (int i = 0; i < 2; i++) {
            if (fds[i].fd < 0 || fds[i].revents == 0) continue;
            ssize_t n = read(fds[i].fd, chunk, sizeof chunk);
            if (n > 0) {
                procbuf_append(i == 0 ? &outbuf : &errbuf, chunk, n);
            } else if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) {
                close(fds[i].fd);
                fds[i].fd = -1;
            }
        }
        if (fds[2].fd >= 0 && fds[2].revents != 0) {
            /* POLLERR without POLLOUT = the child closed its stdin;
             * remaining content is silently dropped, matching the
             * managed twin (its writer throw is absorbed). */
            if ((fds[2].revents & POLLOUT) != 0) {
                ssize_t n = stdin_write(fds[2].fd, in_data + in_off, (size_t)(in_len - in_off));
                if (n > 0) {
                    in_off += n;
                } else if (n < 0 && errno != EINTR && errno != EAGAIN) {
                    in_off = in_len; /* EPIPE or hard error: drop the rest */
                }
            } else {
                in_off = in_len;
            }
            if (in_off >= in_len) {
                close(fds[2].fd);
                fds[2].fd = -1;
            }
        }
    }
    if (fds[0].fd >= 0) close(fds[0].fd);
    if (fds[1].fd >= 0) close(fds[1].fd);
    if (fds[2].fd >= 0) close(fds[2].fd);

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
    if (killed) {
        /* #5107 contract: a child that exited normally before the kill
         * landed is not a timeout — its real status was reaped. */
        timed_out = WIFSIGNALED(status) ? 1 : 0;
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
    if (out_timed_out) *out_timed_out = timed_out;
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
    int in_fd; /* stdin write end; -1 once fully written (or dropped) */
    ProcBuf outbuf;
    ProcBuf errbuf;
    uint8_t* stdin_data; /* owned copy — the caller's string may die first */
    int64_t stdin_len;
    int64_t stdin_off;
    int32_t spawn_failed;
    int32_t done; /* pipes drained AND child reaped */
    int32_t exit_code;
} LyricProcOp;

void* lyric_process_start(const char* path, LyricList* args, LyricString* stdin_content) {
    LyricProcOp* op = (LyricProcOp*)calloc(1, sizeof(LyricProcOp));
    if (!op) lyric_panic_msg("OOM starting process op", "lyric_process.c", __LINE__);
    op->out_fd = -1;
    op->err_fd = -1;
    op->in_fd = -1;
    op->exit_code = -1;
    int64_t in_len = stdin_content ? lyric_string_len(stdin_content) : 0;
    if (in_len > 0) {
        op->stdin_data = (uint8_t*)malloc((size_t)in_len);
        if (!op->stdin_data) lyric_panic_msg("OOM copying process stdin", "lyric_process.c", __LINE__);
        memcpy(op->stdin_data, LYRIC_STRING_DATA(stdin_content), (size_t)in_len);
        op->stdin_len = in_len;
    }
    pid_t pid = spawn_capture(path, args, &op->out_fd, &op->err_fd, &op->in_fd);
    if (pid < 0) {
        op->spawn_failed = 1;
        op->done = 1;
        return op;
    }
    op->pid = pid;
    set_nonblock(op->out_fd);
    set_nonblock(op->err_fd);
    if (op->stdin_len == 0) {
        close(op->in_fd);
        op->in_fd = -1;
    } else {
        set_nonblock(op->in_fd);
    }
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

/* One nonblocking step: flush pending stdin, drain available output;
 * once both output pipes hit EOF, try a WNOHANG reap.  Returns 1 when
 * the op is fully done. */
int32_t lyric_process_pump(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    if (op->done) return 1;
    while (op->in_fd >= 0) {
        ssize_t n = stdin_write(op->in_fd, op->stdin_data + op->stdin_off, (size_t)(op->stdin_len - op->stdin_off));
        if (n > 0) {
            op->stdin_off += n;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            break; /* pipe buffer full; retry next pump */
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            op->stdin_off = op->stdin_len; /* EPIPE or hard error: drop the rest */
        }
        if (op->stdin_off >= op->stdin_len) {
            close(op->in_fd);
            op->in_fd = -1;
        }
    }
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

/* Timeout path: SIGKILL the child's process group (D-N-025), drain
 * what already arrived, close the pipes, and reap (blocking — the
 * child is dead, the reap is immediate).  After this the op is done.
 * Returns 1 when the kill
 * actually terminated the child; 0 when the child had already exited
 * (a SIGKILL landing on a zombie does not alter its status, so the
 * reap reports the child's REAL exit) — the caller must not report a
 * timeout in that case (#5107: the child can finish inside the window
 * between the last WNOHANG pump and the deadline firing). */
int32_t lyric_process_kill(void* raw) {
    LyricProcOp* op = (LyricProcOp*)raw;
    if (op->done) return 0;
    /* Group kill (D-N-025): takes the child's descendants too; the
     * direct-pid fallback covers the cannot-happen case of both
     * setpgid calls failing. */
    if (kill(-op->pid, SIGKILL) != 0) {
        kill(op->pid, SIGKILL);
    }
    if (op->in_fd >= 0) {
        close(op->in_fd);
        op->in_fd = -1;
    }
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
    return w == op->pid && WIFSIGNALED(status) ? 1 : 0;
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
    if (op->in_fd >= 0) close(op->in_fd);
    free(op->stdin_data);
    free(op->outbuf.data);
    free(op->errbuf.data);
    free(op);
}
