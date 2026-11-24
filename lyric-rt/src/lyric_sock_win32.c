/* lyric_sock_win32.c — the Windows twin of lyric_tls.c's socket half
 * (docs/67 G9, #8434): blocking TCP connect / listen / accept / read / write
 * over Winsock 2, the interruptible accept, and the thread-local diagnostic
 * that the TLS half (lyric_tls_win32.c) shares.
 *
 * A SOCKET is a kernel handle, and Windows guarantees handles fit in 32 bits
 * (they may be truncated and sign-extended), so the runtime's int32_t socket
 * descriptors carry it unchanged; INVALID_SOCKET becomes -1.  These
 * descriptors are not UCRT file descriptors: they are only ever passed back
 * to lyric_sock_* and lyric_tls_*.
 *
 * Winsock reports errors through WSAGetLastError, never errno; messages come
 * from FormatMessageW, and lyric_sock_accept_errno reports the WSA code.
 * The wake "pipe" of the interruptible accept is a connected pair of
 * loopback sockets, since WSAPoll waits only on sockets.
 */
#include "lyric_rt.h"
#include "lyric_win32_internal.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Diagnostics shared with the TLS half ──────────────────────────── */

static _Thread_local char g_err[256];
static _Thread_local int32_t g_sock_accept_errno;

void lyric_net_set_err(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
}

int32_t lyric_tls_last_error(char* out, int32_t out_cap) {
    if (!out || out_cap <= 0) return 0;
    size_t n = strlen(g_err);
    if (n > (size_t)(out_cap - 1)) n = (size_t)(out_cap - 1);
    memcpy(out, g_err, n);
    out[n] = '\0';
    return (int32_t)n;
}

LyricString* lyric_tls_last_error_string(void) {
    char buf[256];
    int32_t n = lyric_tls_last_error(buf, (int32_t)sizeof buf);
    return lyric_string_from_literal((const uint8_t*)buf, (int64_t)n);
}

void lyric_win32_message(DWORD code, char* out, size_t cap) {
    wchar_t w[256];
    DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code,
                             MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US), w, sizeof w / sizeof w[0], NULL);
    if (n == 0) {
        n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0, w,
                           sizeof w / sizeof w[0], NULL);
    }
    while (n > 0 && (w[n - 1] == L'\r' || w[n - 1] == L'\n' || w[n - 1] == L' ' || w[n - 1] == L'.')) n--;
    char* s = n > 0 ? lyric_win32_utf8(w, n, NULL) : NULL;
    if (s) {
        snprintf(out, cap, "%s (%lu)", s, (unsigned long)code);
        free(s);
    } else {
        snprintf(out, cap, "error %lu", (unsigned long)code);
    }
}

/* Records `what: <message for the last Winsock error>`. */
static void set_wsa_err(const char* what, int code) {
    char msg[200];
    lyric_win32_message((DWORD)code, msg, sizeof msg);
    lyric_net_set_err("%s: %s", what, msg);
}

/* ── Winsock start-up ──────────────────────────────────────────────── */

static INIT_ONCE wsa_once = INIT_ONCE_STATIC_INIT;
static int wsa_status = -1;

static BOOL CALLBACK wsa_start(PINIT_ONCE once, PVOID param, PVOID* ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    WSADATA data;
    wsa_status = WSAStartup(MAKEWORD(2, 2), &data);
    return TRUE;
}

/* Starts Winsock once per process (it stays up until exit). */
static int wsa_ready(void) {
    InitOnceExecuteOnce(&wsa_once, wsa_start, NULL, NULL);
    if (wsa_status != 0) {
        set_wsa_err("WSAStartup", wsa_status);
        return 0;
    }
    return 1;
}

static SOCKET to_socket(int32_t fd) {
    return fd < 0 ? INVALID_SOCKET : (SOCKET)(intptr_t)fd;
}

static int32_t from_socket(SOCKET s) {
    return s == INVALID_SOCKET ? -1 : (int32_t)(intptr_t)s;
}

/* A new socket that child processes do not inherit. */
static SOCKET new_socket(int family, int type, int protocol) {
    return WSASocketW(family, type, protocol, NULL, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
}

static int set_nonblocking(SOCKET s, int on) {
    u_long mode = on ? 1 : 0;
    return ioctlsocket(s, FIONBIO, &mode) == 0 ? 0 : -1;
}

/* ── Connections ───────────────────────────────────────────────────── */

/* ── Sockets whose read side was shut down ─────────────────────────
 *
 * A read that another thread must be able to end (Std.TcpHost.hostShutdown on
 * an idle keep-alive connection) cannot rely on CancelIoEx alone: it cancels
 * only I/O already pending, so a reader that has not yet issued its recv when
 * the shutdown runs would then block for good, and Winsock does not promise
 * that a recv issued after shutdown(SD_RECEIVE) fails.  The shutdown is
 * therefore also recorded here, and every blocking read waits in short
 * WSAPoll slices that re-check the record (lyric_win32_sock_recv). */

static SRWLOCK g_down_lock = SRWLOCK_INIT;
static SOCKET* g_down;
static size_t g_down_len;
static size_t g_down_cap;

static void down_mark(SOCKET s) {
    AcquireSRWLockExclusive(&g_down_lock);
    int present = 0;
    for (size_t i = 0; i < g_down_len; i++) {
        if (g_down[i] == s) {
            present = 1;
            break;
        }
    }
    if (!present) {
        if (g_down_len == g_down_cap) {
            size_t cap = g_down_cap ? g_down_cap * 2 : 16;
            SOCKET* p = (SOCKET*)realloc(g_down, cap * sizeof *p);
            if (p) {
                g_down = p;
                g_down_cap = cap;
            }
        }
        if (g_down_len < g_down_cap) g_down[g_down_len++] = s;
    }
    ReleaseSRWLockExclusive(&g_down_lock);
}

static int down_has(SOCKET s) {
    int found = 0;
    AcquireSRWLockShared(&g_down_lock);
    for (size_t i = 0; i < g_down_len; i++) {
        if (g_down[i] == s) {
            found = 1;
            break;
        }
    }
    ReleaseSRWLockShared(&g_down_lock);
    return found;
}

/* A closed socket's handle value can be reused, so its record goes with it. */
static void down_clear(SOCKET s) {
    AcquireSRWLockExclusive(&g_down_lock);
    for (size_t i = 0; i < g_down_len; i++) {
        if (g_down[i] == s) {
            g_down[i] = g_down[--g_down_len];
            break;
        }
    }
    ReleaseSRWLockExclusive(&g_down_lock);
}

/* How long a waiting read sleeps between looks at the shutdown record. */
#define LYRIC_SOCK_WAKE_SLICE_MS 50

/* ── The bound of a `*_bounded` operation (#9090) ──────────────────────
 *
 * The bounded entry points run the ordinary read, write and handshake code
 * with the calling thread's bound set: the two places that wait on a socket
 * (lyric_win32_sock_recv and lyric_win32_sock_send) test it, fail with
 * WSAETIMEDOUT when it ends the wait, and record which limit it was. */

static _Thread_local int g_bound_on;
static _Thread_local int64_t g_bound_deadline_ns;
static _Thread_local SOCKET g_bound_wake;
static _Thread_local int32_t g_bound_outcome;

/* Milliseconds until the bound's deadline, rounded up so a wait never ends
 * just before it: -1 without a deadline, 0 once it has passed (recorded). */
static int bound_left_ms(void) {
    if (!g_bound_on || g_bound_deadline_ns == 0) return -1;
    int64_t left = g_bound_deadline_ns - lyric_monotonic_nanos();
    if (left <= 0) {
        g_bound_outcome = LYRIC_BOUNDED_DEADLINE;
        return 0;
    }
    int64_t ms = (left + 999999) / 1000000;
    return ms > 0x7fffffff ? 0x7fffffff : (int)ms;
}

/* Waits under the bound until `s` is ready for `events`: 0 when ready (or
 * failed, which the next call on it reports), -1 with the Winsock error set
 * otherwise (WSAETIMEDOUT when the bound ended the wait). */
static int bound_wait(SOCKET s, short events) {
    for (;;) {
        int wait = bound_left_ms();
        if (wait == 0) {
            WSASetLastError(WSAETIMEDOUT);
            return -1;
        }
        WSAPOLLFD pfd[2];
        ULONG n = 1;
        pfd[0].fd = s;
        pfd[0].events = events;
        pfd[0].revents = 0;
        if (g_bound_on && g_bound_wake != INVALID_SOCKET) {
            pfd[1].fd = g_bound_wake;
            pfd[1].events = POLLRDNORM;
            pfd[1].revents = 0;
            n = 2;
        }
        int ready = WSAPoll(pfd, n, wait);
        if (ready == SOCKET_ERROR) {
            if (WSAGetLastError() == WSAEINTR) continue;
            return -1;
        }
        if (ready == 0) continue; /* bound_left_ms decides */
        if (n == 2 && pfd[1].revents != 0) {
            g_bound_outcome = LYRIC_BOUNDED_INTERRUPTED;
            WSASetLastError(WSAETIMEDOUT);
            return -1;
        }
        if (pfd[0].revents != 0) return 0;
    }
}

/* recv() that a concurrent lyric_sock_shutdown always ends: returns the bytes
 * read, 0 at end of stream or once the read side was shut down, or -1 with
 * the Winsock error set (WSAETIMEDOUT when the socket's SO_RCVTIMEO elapses,
 * as for a plain recv). */
int lyric_win32_sock_recv(uintptr_t sock, char* buf, int len) {
    SOCKET s = (SOCKET)sock;
    DWORD timeout_ms = 0;
    int optlen = (int)sizeof timeout_ms;
    if (getsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout_ms, &optlen) != 0) timeout_ms = 0;
    ULONGLONG deadline = timeout_ms ? GetTickCount64() + timeout_ms : 0;
    for (;;) {
        if (down_has(s)) return 0;
        int slice = LYRIC_SOCK_WAKE_SLICE_MS;
        if (deadline) {
            ULONGLONG now = GetTickCount64();
            if (now >= deadline) {
                WSASetLastError(WSAETIMEDOUT);
                return -1;
            }
            if (deadline - now < (ULONGLONG)slice) slice = (int)(deadline - now);
        }
        int bound_ms = bound_left_ms();
        if (bound_ms == 0) {
            WSASetLastError(WSAETIMEDOUT);
            return -1;
        }
        if (bound_ms > 0 && bound_ms < slice) slice = bound_ms;
        WSAPOLLFD pfd[2];
        ULONG npfd = 1;
        pfd[0].fd = s;
        pfd[0].events = POLLRDNORM;
        pfd[0].revents = 0;
        if (g_bound_on && g_bound_wake != INVALID_SOCKET) {
            pfd[1].fd = g_bound_wake;
            pfd[1].events = POLLRDNORM;
            pfd[1].revents = 0;
            npfd = 2;
        }
        int ready = WSAPoll(pfd, npfd, slice);
        if (ready == SOCKET_ERROR) {
            int e = WSAGetLastError();
            if (e == WSAEINTR) continue;
            return -1;
        }
        if (ready == 0) continue;
        if (npfd == 2 && pfd[1].revents != 0) {
            g_bound_outcome = LYRIC_BOUNDED_INTERRUPTED;
            WSASetLastError(WSAETIMEDOUT);
            return -1;
        }
        if (pfd[0].revents == 0) continue;
        /* Readable, hung up or failed: recv reports which without blocking. A
         * shutdown that landed in between is seen first. */
        if (down_has(s)) return 0;
        int got = recv(s, buf, len, 0);
        if (got >= 0) return got;
        int e = WSAGetLastError();
        if (e == WSAEINTR) continue;
        if (e == WSAEWOULDBLOCK) continue;
        return -1;
    }
}

int32_t lyric_sock_close(int32_t fd) {
    if (fd < 0) return 0;
    down_clear(to_socket(fd));
    return closesocket(to_socket(fd)) == 0 ? 0 : -1;
}

/* `how` uses the POSIX values (0 read, 1 write, 2 both), which equal
 * SD_RECEIVE, SD_SEND and SD_BOTH.  The seam's callers use shutdown to wake
 * another thread blocked in a read or write on the socket, which POSIX
 * shutdown does and Winsock's does not: a blocking call on an overlapped
 * socket waits on its own I/O, so the shutdown also cancels that I/O, and the
 * blocked call fails with WSA_OPERATION_ABORTED. */
int32_t lyric_sock_shutdown(int32_t fd, int32_t how) {
    SOCKET s = to_socket(fd);
    /* Recorded before the shutdown, so a read that starts at any later point
     * sees it (lyric_win32_sock_recv). */
    if (how != 1) down_mark(s);
    int rc = shutdown(s, how);
    /* A write-only half-close leaves reads alone.  The cancel is a best-effort
     * wake-up of pending writes and handshakes: with nothing pending it fails
     * with ERROR_NOT_FOUND, which is not an error for the caller. */
    if (how != 1) CancelIoEx((HANDLE)s, NULL);
    return rc == 0 ? 0 : -1;
}

LyricString* lyric_sock_peer_string(int32_t fd) {
    struct sockaddr_storage ss;
    int len = (int)sizeof ss;
    char ip[INET6_ADDRSTRLEN];
    char out[INET6_ADDRSTRLEN + 16];
    if (fd < 0 || getpeername(to_socket(fd), (struct sockaddr*)&ss, &len) != 0) {
        return lyric_string_from_literal((const uint8_t*)"", 0);
    }
    int n;
    if (ss.ss_family == AF_INET) {
        const struct sockaddr_in* a = (const struct sockaddr_in*)&ss;
        if (inet_ntop(AF_INET, &a->sin_addr, ip, sizeof ip) == NULL) {
            return lyric_string_from_literal((const uint8_t*)"", 0);
        }
        n = snprintf(out, sizeof out, "%s:%u", ip, (unsigned)ntohs(a->sin_port));
    } else if (ss.ss_family == AF_INET6) {
        const struct sockaddr_in6* a = (const struct sockaddr_in6*)&ss;
        if (inet_ntop(AF_INET6, &a->sin6_addr, ip, sizeof ip) == NULL) {
            return lyric_string_from_literal((const uint8_t*)"", 0);
        }
        n = snprintf(out, sizeof out, "[%s]:%u", ip, (unsigned)ntohs(a->sin6_port));
    } else {
        return lyric_string_from_literal((const uint8_t*)"", 0);
    }
    return lyric_string_from_literal((const uint8_t*)out, (int64_t)n);
}

/* Resolves `host`:`port` with GetAddrInfoW, so a non-ASCII host name works.
 * 0 and *out on success; otherwise last_error is set. */
static int resolve(const char* host, int32_t port, int passive, ADDRINFOW** out) {
    wchar_t* whost = lyric_win32_wide(host);
    if (!whost) {
        lyric_net_set_err("resolve %s: the host name is not valid UTF-8", host);
        return -1;
    }
    wchar_t wport[16];
    _snwprintf(wport, sizeof wport / sizeof wport[0], L"%d", (int)port);
    wport[sizeof wport / sizeof wport[0] - 1] = L'\0';
    ADDRINFOW hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    if (passive) hints.ai_flags = AI_PASSIVE | AI_NUMERICHOST;
    int rc = GetAddrInfoW(whost, wport, &hints, out);
    free(whost);
    if (rc != 0) {
        set_wsa_err(passive ? "bind address" : "resolve", rc);
        return -1;
    }
    return 0;
}

int32_t lyric_sock_connect(const char* host, int32_t port) {
    if (!host || port < 0 || port > 65535) {
        lyric_net_set_err("invalid host/port");
        return -1;
    }
    if (!wsa_ready()) return -1;
    ADDRINFOW* res = NULL;
    if (resolve(host, port, 0, &res) != 0) return -1;
    SOCKET s = INVALID_SOCKET;
    int last = 0;
    for (ADDRINFOW* ai = res; ai != NULL; ai = ai->ai_next) {
        s = new_socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == INVALID_SOCKET) {
            last = WSAGetLastError();
            continue;
        }
        if (connect(s, ai->ai_addr, (int)ai->ai_addrlen) == 0) break;
        last = WSAGetLastError();
        closesocket(s);
        s = INVALID_SOCKET;
    }
    FreeAddrInfoW(res);
    if (s == INVALID_SOCKET) {
        char what[300];
        snprintf(what, sizeof what, "connect %s:%d", host, (int)port);
        if (last) {
            set_wsa_err(what, last);
        } else {
            lyric_net_set_err("%s: no usable address", what);
        }
        return -1;
    }
    return from_socket(s);
}

int32_t lyric_sock_listen(const char* ip, int32_t port, int32_t backlog) {
    if (!ip || port < 0 || port > 65535) {
        lyric_net_set_err("invalid bind address/port");
        return -1;
    }
    if (!wsa_ready()) return -1;
    ADDRINFOW* res = NULL;
    if (resolve(ip, port, 1, &res) != 0) return -1;
    SOCKET s = INVALID_SOCKET;
    int last = 0;
    for (ADDRINFOW* ai = res; ai != NULL; ai = ai->ai_next) {
        s = new_socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == INVALID_SOCKET) {
            last = WSAGetLastError();
            continue;
        }
        /* SO_EXCLUSIVEADDRUSE, not SO_REUSEADDR: on Windows SO_REUSEADDR lets
         * another socket bind the same port and take its connections. A
         * listener in TIME_WAIT does not block a rebind on Windows. */
        BOOL one = TRUE;
        setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char*)&one, sizeof one);
        if (bind(s, ai->ai_addr, (int)ai->ai_addrlen) == 0 && listen(s, backlog > 0 ? backlog : 128) == 0) {
            break;
        }
        last = WSAGetLastError();
        closesocket(s);
        s = INVALID_SOCKET;
    }
    FreeAddrInfoW(res);
    char what[300];
    snprintf(what, sizeof what, "listen %s:%d", ip, (int)port);
    if (s == INVALID_SOCKET) {
        if (last) {
            set_wsa_err(what, last);
        } else {
            lyric_net_set_err("%s: no usable address", what);
        }
        return -1;
    }
    /* Nonblocking, as on POSIX (#6962): accept waits for readiness first, so
     * two threads accepting on one listener cannot leave the loser blocked. */
    if (set_nonblocking(s, 1) != 0) {
        set_wsa_err(what, WSAGetLastError());
        closesocket(s);
        return -1;
    }
    return from_socket(s);
}

int32_t lyric_sock_local_port(int32_t fd) {
    struct sockaddr_storage ss;
    int len = (int)sizeof ss;
    if (getsockname(to_socket(fd), (struct sockaddr*)&ss, &len) != 0) {
        set_wsa_err("getsockname", WSAGetLastError());
        return -1;
    }
    if (ss.ss_family == AF_INET) return (int32_t)ntohs(((struct sockaddr_in*)&ss)->sin_port);
    if (ss.ss_family == AF_INET6) return (int32_t)ntohs(((struct sockaddr_in6*)&ss)->sin6_port);
    lyric_net_set_err("getsockname: unknown address family");
    return -1;
}

/* An accepted socket inherits the listener's nonblocking mode; connections
 * are blocking (their reads and writes wait, bounded by
 * lyric_sock_set_timeouts). */
static int32_t accepted(SOCKET c) {
    /* A spawned child inherits only the handles it is given, but keep an
     * accepted socket non-inheritable like every socket this file creates. */
    SetHandleInformation((HANDLE)c, HANDLE_FLAG_INHERIT, 0);
    if (set_nonblocking(c, 0) != 0) {
        int e = WSAGetLastError();
        closesocket(c);
        g_sock_accept_errno = e;
        set_wsa_err("accept", e);
        return -1;
    }
    g_sock_accept_errno = 0;
    return from_socket(c);
}

int32_t lyric_sock_accept(int32_t listen_fd) {
    SOCKET l = to_socket(listen_fd);
    for (;;) {
        SOCKET c = accept(l, NULL, NULL);
        if (c != INVALID_SOCKET) return accepted(c);
        int e = WSAGetLastError();
        if (e == WSAEWOULDBLOCK) {
            WSAPOLLFD p;
            p.fd = l;
            p.events = POLLRDNORM;
            p.revents = 0;
            if (WSAPoll(&p, 1, -1) != SOCKET_ERROR) continue;
            e = WSAGetLastError();
        }
        if (e == WSAEINTR) continue;
        g_sock_accept_errno = e;
        set_wsa_err("accept", e);
        return -1;
    }
}

int32_t lyric_sock_accept_errno(void) {
    return g_sock_accept_errno;
}

/* The POSIX twin's classes over the Winsock codes: 1 for a failure of the
 * one pending connection, 2 for exhausted descriptors or buffers, 0 for the
 * listener itself failing. */
int32_t lyric_sock_accept_error_class(void) {
    switch (g_sock_accept_errno) {
    case WSAECONNABORTED:
    case WSAECONNRESET:
    case WSAENETDOWN:
    case WSAENOPROTOOPT:
    case WSAEHOSTDOWN:
    case WSAEHOSTUNREACH:
    case WSAEOPNOTSUPP:
    case WSAENETUNREACH:
        return 1;
    case WSAEMFILE:
    case WSAENOBUFS:
        return 2;
    default:
        return 0;
    }
}

/* ── Interruptible accept ──────────────────────────────────────────── */

/* A connected pair of loopback sockets: the read end is nonblocking, so a
 * drain stops when it is empty, and the write end is nonblocking, so a
 * signal never waits.  The accepted end is checked to be the peer of the
 * end this function connected, so no other local process can take its
 * place. */
int32_t lyric_sock_wake_pipe_new(int32_t* read_fd_out, int32_t* write_fd_out) {
    if (!read_fd_out || !write_fd_out) {
        lyric_net_set_err("lyric_sock_wake_pipe_new: null out-param");
        return -1;
    }
    if (!wsa_ready()) return -1;
    SOCKET l = new_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    SOCKET w = INVALID_SOCKET;
    SOCKET r = INVALID_SOCKET;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    int len = (int)sizeof addr;
    int e = 0;
    if (l == INVALID_SOCKET || bind(l, (struct sockaddr*)&addr, sizeof addr) != 0 ||
        getsockname(l, (struct sockaddr*)&addr, &len) != 0 || listen(l, 1) != 0) {
        e = WSAGetLastError();
        goto fail;
    }
    w = new_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (w == INVALID_SOCKET || connect(w, (struct sockaddr*)&addr, sizeof addr) != 0) {
        e = WSAGetLastError();
        goto fail;
    }
    for (int attempt = 0; attempt < 8 && r == INVALID_SOCKET; attempt++) {
        struct sockaddr_in peer;
        int peer_len = (int)sizeof peer;
        SOCKET c = accept(l, (struct sockaddr*)&peer, &peer_len);
        if (c == INVALID_SOCKET) {
            e = WSAGetLastError();
            goto fail;
        }
        struct sockaddr_in mine;
        int mine_len = (int)sizeof mine;
        if (getsockname(w, (struct sockaddr*)&mine, &mine_len) == 0 && peer.sin_port == mine.sin_port &&
            peer.sin_addr.s_addr == mine.sin_addr.s_addr) {
            r = c;
        } else {
            closesocket(c); /* someone else's connection */
        }
    }
    if (r == INVALID_SOCKET) {
        lyric_net_set_err("wake socket pair: the loopback connection was not accepted");
        closesocket(l);
        closesocket(w);
        return -1;
    }
    closesocket(l);
    l = INVALID_SOCKET;
    BOOL one = TRUE;
    setsockopt(w, IPPROTO_TCP, TCP_NODELAY, (const char*)&one, sizeof one);
    if (set_nonblocking(r, 1) != 0 || set_nonblocking(w, 1) != 0) {
        e = WSAGetLastError();
        goto fail;
    }
    *read_fd_out = from_socket(r);
    *write_fd_out = from_socket(w);
    return 0;
fail:
    set_wsa_err("wake socket pair", e);
    if (l != INVALID_SOCKET) closesocket(l);
    if (w != INVALID_SOCKET) closesocket(w);
    if (r != INVALID_SOCKET) closesocket(r);
    return -1;
}

int32_t lyric_sock_listener_refuse(int32_t listen_fd) {
    (void)listen_fd;
    return 0;
}

int32_t lyric_sock_wake_pipe_signal(int32_t write_fd) {
    if (write_fd < 0) return 0;
    char b = 1;
    if (send(to_socket(write_fd), &b, 1, 0) == 1) return 0;
    int e = WSAGetLastError();
    /* A full buffer already holds unread wake bytes: the waiter will wake. */
    if (e == WSAEWOULDBLOCK) return 0;
    set_wsa_err("send (wake socket)", e);
    return -1;
}

int32_t lyric_sock_accept_interruptible(int32_t listen_fd, int32_t wake_read_fd) {
    WSAPOLLFD fds[2];
    fds[0].fd = to_socket(listen_fd);
    fds[0].events = POLLRDNORM;
    fds[1].fd = to_socket(wake_read_fd);
    fds[1].events = POLLRDNORM;
    for (;;) {
        fds[0].revents = 0;
        fds[1].revents = 0;
        if (WSAPoll(fds, 2, -1) == SOCKET_ERROR) {
            int e = WSAGetLastError();
            if (e == WSAEINTR) continue;
            g_sock_accept_errno = e;
            set_wsa_err("poll (accept)", e);
            return -1;
        }
        if (fds[1].revents & (POLLRDNORM | POLLHUP | POLLERR | POLLNVAL)) {
            char drain[64];
            while (recv(fds[1].fd, drain, sizeof drain, 0) > 0) {
            }
            g_sock_accept_errno = 0;
            lyric_net_set_err((fds[1].revents & POLLRDNORM) ? "accept interrupted: listener stopped"
                                                             : "accept interrupted: wake socket closed");
            return -2;
        }
        if (fds[0].revents & POLLRDNORM) {
            SOCKET c = accept(fds[0].fd, NULL, NULL);
            if (c != INVALID_SOCKET) return accepted(c);
            int e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK || e == WSAEINTR) continue; /* another thread took it */
            g_sock_accept_errno = e;
            set_wsa_err("accept", e);
            return -1;
        }
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            g_sock_accept_errno = 0;
            lyric_net_set_err("accept: listening socket error");
            return -1;
        }
    }
}

/* ── Reads and writes ──────────────────────────────────────────────── */

static int sock_make_nonblocking(SOCKET s);

/* 0 clears both timeouts (wait without a bound), as on POSIX.  After a
 * timed-out read or write Windows leaves the socket in an indeterminate
 * state, so the kernels close a connection whose read timed out. */
int32_t lyric_sock_set_timeouts(int32_t fd, int32_t timeout_ms) {
    if (timeout_ms < 0) {
        lyric_net_set_err("socket timeout must be >= 0, got %d", (int)timeout_ms);
        return -1;
    }
    DWORD ms = (DWORD)timeout_ms;
    SOCKET s = to_socket(fd);
    if (setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char*)&ms, sizeof ms) != 0 ||
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char*)&ms, sizeof ms) != 0) {
        set_wsa_err("setsockopt timeout", WSAGetLastError());
        return -1;
    }
    return 0;
}

int lyric_win32_sock_timed_out(int wsa_error) {
    return wsa_error == WSAETIMEDOUT || wsa_error == WSAEWOULDBLOCK;
}

int64_t lyric_sock_read(int32_t fd, uint8_t* buf, int64_t n) {
    if (n <= 0) return 0;
    int want = n > INT32_MAX ? INT32_MAX : (int)n;
    for (;;) {
        int got = lyric_win32_sock_recv(to_socket(fd), (char*)buf, want);
        if (got >= 0) return (int64_t)got;
        int e = WSAGetLastError();
        if (e == WSAEINTR) continue;
        if (lyric_win32_sock_timed_out(e)) {
            lyric_net_set_err("read: timed out");
        } else {
            set_wsa_err("read", e);
        }
        return -1;
    }
}

/* Waits until `s` can take more bytes, for a socket the reactor left
 * non-blocking: 1 when writable (or failed, which the next send reports), 0
 * when SO_SNDTIMEO elapsed, -1 on a WSAPoll error. */
static int sock_wait_writable(SOCKET s, ULONGLONG* deadline) {
    if (*deadline == 0) {
        DWORD timeout_ms = 0;
        int optlen = (int)sizeof timeout_ms;
        if (getsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (char*)&timeout_ms, &optlen) != 0) timeout_ms = 0;
        *deadline = timeout_ms ? GetTickCount64() + timeout_ms : (ULONGLONG)-1;
    }
    for (;;) {
        int wait = -1;
        if (*deadline != (ULONGLONG)-1) {
            ULONGLONG now = GetTickCount64();
            if (now >= *deadline) return 0;
            ULONGLONG left = *deadline - now;
            wait = left > 0x7fffffff ? 0x7fffffff : (int)left;
        }
        WSAPOLLFD pfd;
        pfd.fd = s;
        pfd.events = POLLWRNORM;
        pfd.revents = 0;
        int ready = WSAPoll(&pfd, 1, wait);
        if (ready > 0) return 1;
        if (ready == SOCKET_ERROR) {
            if (WSAGetLastError() == WSAEINTR) continue;
            return -1;
        }
    }
}

int lyric_win32_sock_send(uintptr_t sock, const char* buf, int len) {
    SOCKET s = (SOCKET)sock;
    ULONGLONG deadline = 0;
    for (;;) {
        int w = send(s, buf, len, 0);
        if (w != SOCKET_ERROR) return w;
        int e = WSAGetLastError();
        if (e == WSAEINTR) continue;
        if (e != WSAEWOULDBLOCK) {
            WSASetLastError(e);
            return -1;
        }
        /* A non-blocking socket with a full send buffer. */
        if (g_bound_on) {
            if (bound_wait(s, POLLWRNORM) != 0) return -1;
        } else {
            int r = sock_wait_writable(s, &deadline);
            if (r == 0) {
                WSASetLastError(WSAETIMEDOUT);
                return -1;
            }
            if (r < 0) return -1;
        }
    }
}

int lyric_win32_bound_begin(uintptr_t sock, int64_t deadline_ns, int32_t wake_fd) {
    if (sock_make_nonblocking((SOCKET)sock) != 0) {
        set_wsa_err("non-blocking mode", WSAGetLastError());
        return -1;
    }
    g_bound_deadline_ns = deadline_ns;
    g_bound_wake = to_socket(wake_fd);
    g_bound_outcome = 0;
    g_bound_on = 1;
    return 0;
}

int32_t lyric_win32_bound_end(int ok, const char* what) {
    int32_t outcome = g_bound_outcome;
    g_bound_on = 0;
    g_bound_outcome = 0;
    if (ok) return LYRIC_BOUNDED_OK;
    if (outcome == LYRIC_BOUNDED_DEADLINE) {
        lyric_net_set_err("%s: timed out", what);
        return LYRIC_BOUNDED_DEADLINE;
    }
    if (outcome == LYRIC_BOUNDED_INTERRUPTED) {
        lyric_net_set_err("%s: interrupted", what);
        return LYRIC_BOUNDED_INTERRUPTED;
    }
    return LYRIC_BOUNDED_ERROR;
}

int64_t lyric_sock_write(int32_t fd, const uint8_t* buf, int64_t n) {
    int64_t off = 0;
    ULONGLONG deadline = 0;
    while (off < n) {
        int64_t left = n - off;
        int chunk = left > INT32_MAX ? INT32_MAX : (int)left;
        int w = lyric_win32_sock_send(to_socket(fd), (const char*)buf + off, chunk);
        if (w < 0) {
            int e = WSAGetLastError();
            if (e == WSAEINTR) continue;
            if (e == WSAEWOULDBLOCK) {
                /* A socket the async twins have used is non-blocking. */
                int r = sock_wait_writable(to_socket(fd), &deadline);
                if (r == 1) continue;
                if (r == 0) {
                    lyric_net_set_err("write: timed out");
                } else {
                    set_wsa_err("write", WSAGetLastError());
                }
                return -1;
            }
            if (lyric_win32_sock_timed_out(e)) {
                lyric_net_set_err("write: timed out");
            } else {
                set_wsa_err("write", e);
            }
            return -1;
        }
        if (w == 0) {
            lyric_net_set_err("write: no progress");
            return -1;
        }
        off += w;
    }
    return n;
}

/* ── Non-blocking forms for the async I/O reactor (#8494) ─────────────── */

/* The listener is non-blocking (see lyric_sock_accept): one attempt. */
int32_t lyric_sock_try_accept(int32_t listen_fd) {
    SOCKET l = to_socket(listen_fd);
    for (;;) {
        SOCKET c = accept(l, NULL, NULL);
        if (c != INVALID_SOCKET) return accepted(c);
        int e = WSAGetLastError();
        if (e == WSAEINTR) continue;
        if (e == WSAEWOULDBLOCK) return -2;
        g_sock_accept_errno = e;
        set_wsa_err("accept", e);
        return -1;
    }
}

/* Winsock has no per-call MSG_DONTWAIT, and FIONBIO is a property of the
 * socket, so switching it for one call and back would race with another task
 * reading or writing the same connection.  The first non-blocking attempt
 * leaves the connection non-blocking for good; the blocking forms wait in
 * WSAPoll when a call would block (lyric_win32_sock_recv, lyric_sock_write),
 * so they behave the same in either mode. */
static int sock_make_nonblocking(SOCKET s) {
    u_long v = 1;
    return ioctlsocket(s, FIONBIO, &v) == 0 ? 0 : -1;
}

LyricList* lyric_sock_try_read_bytes(int32_t fd, int64_t max_bytes, int32_t* status) {
    LyricList* list = lyric_list_new(0);
    if (max_bytes <= 0) {
        *status = 1;
        return list;
    }
    int cap = max_bytes > 0x7fffffff ? 0x7fffffff : (int)max_bytes;
    char* buf = (char*)malloc((size_t)cap);
    if (!buf) {
        lyric_net_set_err("out of memory");
        *status = 0;
        return list;
    }
    SOCKET s = to_socket(fd);
    if (sock_make_nonblocking(s) != 0) {
        free(buf);
        set_wsa_err("read", WSAGetLastError());
        *status = 0;
        return list;
    }
    int got = recv(s, buf, cap, 0);
    int e = got == SOCKET_ERROR ? WSAGetLastError() : 0;
    if (got == SOCKET_ERROR) {
        free(buf);
        if (e == WSAEWOULDBLOCK) {
            *status = 2;
        } else {
            set_wsa_err("read", e);
            *status = 0;
        }
        return list;
    }
    for (int i = 0; i < got; i++) lyric_list_push(list, (int64_t)(uint8_t)buf[i]);
    free(buf);
    *status = 1;
    return list;
}

int64_t lyric_sock_try_write_bytes(int32_t fd, void* bytes_list, int64_t offset) {
    LyricList* list = (LyricList*)bytes_list;
    int64_t n = (list ? list->len : 0) - offset;
    if (n <= 0) return 0;
    if (n > LYRIC_SOCK_TRY_WRITE_CHUNK) n = LYRIC_SOCK_TRY_WRITE_CHUNK;
    SOCKET s = to_socket(fd);
    if (sock_make_nonblocking(s) != 0) {
        set_wsa_err("write", WSAGetLastError());
        return -1;
    }
    char* buf = (char*)malloc((size_t)n);
    if (!buf) {
        lyric_net_set_err("out of memory");
        return -1;
    }
    for (int64_t i = 0; i < n; i++) buf[i] = (char)(list->data[offset + i] & 0xff);
    int w = send(s, buf, (int)n, 0);
    int e = w == SOCKET_ERROR ? WSAGetLastError() : 0;
    free(buf);
    if (w == SOCKET_ERROR) {
        if (e == WSAEWOULDBLOCK) return -2;
        set_wsa_err("write", e);
        return -1;
    }
    return (int64_t)w;
}

int32_t lyric_sock_io_timeout_ms(int32_t fd) {
    DWORD ms = 0;
    int len = (int)sizeof ms;
    if (getsockopt(to_socket(fd), SOL_SOCKET, SO_RCVTIMEO, (char*)&ms, &len) != 0 || ms == 0) {
        return -1;
    }
    return ms > 0x7fffffff ? 0x7fffffff : (int32_t)ms;
}

/* LyricList[Byte] bridging, as in lyric_tls.c (one byte per 64-bit slot). */
LyricList* lyric_sock_read_bytes(int32_t fd, int64_t max_bytes, int32_t* ok) {
    LyricList* list = lyric_list_new(0);
    if (max_bytes <= 0) {
        *ok = 1;
        return list;
    }
    uint8_t* buf = (uint8_t*)malloc((size_t)max_bytes);
    if (!buf) {
        lyric_net_set_err("out of memory");
        *ok = 0;
        return list;
    }
    int64_t n = lyric_sock_read(fd, buf, max_bytes);
    if (n < 0) {
        free(buf);
        *ok = 0;
        return list;
    }
    for (int64_t i = 0; i < n; i++) lyric_list_push(list, (int64_t)buf[i]);
    free(buf);
    *ok = 1;
    return list;
}

int64_t lyric_sock_write_bytes(int32_t fd, void* bytes_list) {
    LyricList* list = (LyricList*)bytes_list;
    int64_t n = list ? list->len : 0;
    if (n <= 0) return 0;
    uint8_t* buf = (uint8_t*)malloc((size_t)n);
    if (!buf) {
        lyric_net_set_err("out of memory");
        return -1;
    }
    for (int64_t i = 0; i < n; i++) buf[i] = (uint8_t)(list->data[i] & 0xff);
    int64_t rc = lyric_sock_write(fd, buf, n);
    free(buf);
    return rc;
}

/* ── Bounded operations (#9090; lyric_rt.h) ─────────────────────────── */

LyricList* lyric_sock_read_bytes_bounded(int32_t fd, int64_t max_bytes, int64_t deadline_ns, int32_t wake_fd,
                                         int32_t* status) {
    if (lyric_win32_bound_begin(to_socket(fd), deadline_ns, wake_fd) != 0) {
        *status = LYRIC_BOUNDED_ERROR;
        return lyric_list_new(0);
    }
    int32_t ok = 0;
    LyricList* list = lyric_sock_read_bytes(fd, max_bytes, &ok);
    *status = lyric_win32_bound_end(ok == 1, "read");
    return list;
}

int32_t lyric_sock_write_bytes_bounded(int32_t fd, void* bytes_list, int64_t deadline_ns, int32_t wake_fd) {
    if (lyric_win32_bound_begin(to_socket(fd), deadline_ns, wake_fd) != 0) return LYRIC_BOUNDED_ERROR;
    int64_t rc = lyric_sock_write_bytes(fd, bytes_list);
    return lyric_win32_bound_end(rc >= 0, "write");
}

/* One name lookup on a helper thread: GetAddrInfoW cannot be given a
 * deadline.  The waiter and the helper each hold a reference; the job is
 * freed with the last one, so a waiter that gives up leaves the helper to
 * finish on its own. */
typedef struct {
    char* host;
    int32_t port;
    ADDRINFOW* res;
    int ok;
    char err[256];
    HANDLE done;
    volatile LONG refs;
} resolve_job;

/* The most name lookups that may be in flight at once, abandoned ones
 * included: a helper counts from the moment its thread starts until
 * GetAddrInfoW returns.  A further bounded connect to a name fails with
 * "too many name lookups in flight" until one returns (#9137, D608).  The
 * Linux twin is LYRIC_RESOLVE_MAX_INFLIGHT in lyric_tls.c. */
#define LYRIC_RESOLVE_MAX_INFLIGHT 32
static volatile LONG g_resolve_inflight = 0;

static void resolve_job_release(resolve_job* j) {
    if (InterlockedDecrement(&j->refs) != 0) return;
    if (j->res) FreeAddrInfoW(j->res);
    if (j->done) CloseHandle(j->done);
    free(j->host);
    free(j);
}

static DWORD WINAPI resolve_thread(LPVOID param) {
    resolve_job* j = (resolve_job*)param;
    ADDRINFOW* res = NULL;
    int ok = resolve(j->host, j->port, 0, &res) == 0;
    if (!ok) lyric_tls_last_error(j->err, (int32_t)sizeof j->err);
    InterlockedDecrement(&g_resolve_inflight);
    j->res = res;
    j->ok = ok;
    SetEvent(j->done);
    resolve_job_release(j);
    return 0;
}

/* 1 when the wake socket of the calling thread's bound is readable. */
static int bound_wake_ready(void) {
    if (g_bound_wake == INVALID_SOCKET) return 0;
    WSAPOLLFD pfd;
    pfd.fd = g_bound_wake;
    pfd.events = POLLRDNORM;
    pfd.revents = 0;
    return WSAPoll(&pfd, 1, 0) > 0 && pfd.revents != 0;
}

/* resolve() under the calling thread's bound: 0 and *out, or -1 (the bound's
 * outcome is recorded when it ended the wait; otherwise last_error is set).
 * An address literal is parsed on the calling thread. */
static int resolve_bounded(const char* host, int32_t port, ADDRINFOW** out) {
    wchar_t* whost = lyric_win32_wide(host);
    if (!whost) {
        lyric_net_set_err("resolve %s: the host name is not valid UTF-8", host);
        return -1;
    }
    wchar_t wport[16];
    _snwprintf(wport, sizeof wport / sizeof wport[0], L"%d", (int)port);
    wport[sizeof wport / sizeof wport[0] - 1] = L'\0';
    ADDRINFOW hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags = AI_NUMERICHOST;
    int numeric = GetAddrInfoW(whost, wport, &hints, out);
    free(whost);
    if (numeric == 0) return 0;
    *out = NULL;

    resolve_job* j = (resolve_job*)calloc(1, sizeof *j);
    if (j) {
        j->refs = 2;
        j->port = port;
        j->host = _strdup(host);
        j->done = CreateEventW(NULL, TRUE, FALSE, NULL);
    }
    if (!j || !j->host || !j->done) {
        lyric_net_set_err("resolve %s: out of memory", host);
        if (j) {
            j->refs = 1;
            resolve_job_release(j);
        }
        return -1;
    }
    if (InterlockedIncrement(&g_resolve_inflight) > LYRIC_RESOLVE_MAX_INFLIGHT) {
        InterlockedDecrement(&g_resolve_inflight);
        lyric_net_set_err("resolve %s: too many name lookups in flight", host);
        j->refs = 1;
        resolve_job_release(j);
        return -1;
    }
    HANDLE th = CreateThread(NULL, 0, resolve_thread, j, 0, NULL);
    if (!th) {
        InterlockedDecrement(&g_resolve_inflight);
        lyric_net_set_err("resolve %s: cannot start the lookup thread", host);
        j->refs = 1;
        resolve_job_release(j);
        return -1;
    }
    CloseHandle(th);
    int rc = -1;
    for (;;) {
        /* The limits are tested before the answer, as on POSIX. */
        if (bound_wake_ready()) {
            g_bound_outcome = LYRIC_BOUNDED_INTERRUPTED;
            break;
        }
        int slice = LYRIC_SOCK_WAKE_SLICE_MS;
        int left = bound_left_ms();
        if (left == 0) break; /* the deadline, recorded by bound_left_ms */
        if (left > 0 && left < slice) slice = left;
        if (WaitForSingleObject(j->done, (DWORD)slice) == WAIT_OBJECT_0) {
            if (j->ok) {
                *out = j->res;
                j->res = NULL;
                rc = 0;
            } else {
                lyric_net_set_err("%s", j->err);
            }
            break;
        }
    }
    resolve_job_release(j);
    return rc;
}

/* Waits under the bound for a non-blocking connect on `s` to finish: 0 when
 * it has (SO_ERROR says how), -1 otherwise.  select, not WSAPoll: a failed
 * connect is reported through the exception set on every Windows release. */
static int connect_wait(SOCKET s) {
    for (;;) {
        int left = bound_left_ms();
        if (left == 0) return -1;
        struct timeval tv;
        tv.tv_sec = left / 1000;
        tv.tv_usec = (left % 1000) * 1000;
        fd_set rs, ws, es;
        FD_ZERO(&rs);
        FD_ZERO(&ws);
        FD_ZERO(&es);
        FD_SET(s, &ws);
        FD_SET(s, &es);
        int has_wake = g_bound_wake != INVALID_SOCKET;
        if (has_wake) FD_SET(g_bound_wake, &rs);
        int rc = select(0, has_wake ? &rs : NULL, &ws, &es, left < 0 ? NULL : &tv);
        if (rc == SOCKET_ERROR) return -1;
        if (rc == 0) continue; /* bound_left_ms decides */
        if (has_wake && FD_ISSET(g_bound_wake, &rs)) {
            g_bound_outcome = LYRIC_BOUNDED_INTERRUPTED;
            return -1;
        }
        return 0;
    }
}

int32_t lyric_sock_connect_bounded(const char* host, int32_t port, int64_t deadline_ns, int32_t wake_fd) {
    if (deadline_ns == 0 && wake_fd < 0) return lyric_sock_connect(host, port);
    if (!host || port < 0 || port > 65535) {
        lyric_net_set_err("invalid host/port");
        return -1;
    }
    if (!wsa_ready()) return -1;
    char what[300];
    snprintf(what, sizeof what, "connect %s:%d", host, (int)port);
    g_bound_deadline_ns = deadline_ns;
    g_bound_wake = to_socket(wake_fd);
    g_bound_outcome = 0;
    g_bound_on = 1;

    ADDRINFOW* res = NULL;
    SOCKET s = INVALID_SOCKET;
    int last = 0;
    int have_error = 0; /* last_error already describes the failure */
    if (resolve_bounded(host, port, &res) != 0) {
        have_error = 1;
    } else {
        for (ADDRINFOW* ai = res; ai != NULL && g_bound_outcome == 0; ai = ai->ai_next) {
            s = new_socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
            if (s == INVALID_SOCKET) {
                last = WSAGetLastError();
                continue;
            }
            int err = 0;
            if (set_nonblocking(s, 1) != 0) {
                err = WSAGetLastError();
            } else if (connect(s, ai->ai_addr, (int)ai->ai_addrlen) != 0) {
                err = WSAGetLastError();
                if (err == WSAEWOULDBLOCK) {
                    if (connect_wait(s) != 0) {
                        err = g_bound_outcome != 0 ? WSAETIMEDOUT : WSAGetLastError();
                    } else {
                        int len = (int)sizeof err;
                        if (getsockopt(s, SOL_SOCKET, SO_ERROR, (char*)&err, &len) != 0) err = WSAGetLastError();
                    }
                }
            }
            if (err == 0 && set_nonblocking(s, 0) != 0) err = WSAGetLastError();
            if (err == 0) break; /* connected */
            last = err;
            closesocket(s);
            s = INVALID_SOCKET;
        }
        FreeAddrInfoW(res);
    }
    int32_t status = lyric_win32_bound_end(s != INVALID_SOCKET, what);
    if (status == LYRIC_BOUNDED_OK) return from_socket(s);
    if (status == LYRIC_BOUNDED_DEADLINE) return -2;
    if (status == LYRIC_BOUNDED_INTERRUPTED) return -3;
    if (!have_error) {
        if (last) {
            set_wsa_err(what, last);
        } else {
            lyric_net_set_err("%s: no usable address", what);
        }
    }
    return -1;
}

/* The registered wake sockets, under lyric_global_lock. */
typedef struct {
    void* key;
    int32_t write_fd;
} cancel_wake_entry;

static cancel_wake_entry* g_cancel_wakes;
static size_t g_cancel_wake_count;
static size_t g_cancel_wake_cap;

void lyric_cancel_wake_register(void* key, int32_t write_fd) {
    lyric_global_lock();
    if (g_cancel_wake_count == g_cancel_wake_cap) {
        size_t cap = g_cancel_wake_cap ? g_cancel_wake_cap * 2 : 8;
        cancel_wake_entry* grown = (cancel_wake_entry*)realloc(g_cancel_wakes, cap * sizeof *grown);
        if (!grown) {
            lyric_global_unlock();
            lyric_panic_msg("out of memory registering a cancellation wake-up", "lyric_sock_win32.c", __LINE__);
        }
        g_cancel_wakes = grown;
        g_cancel_wake_cap = cap;
    }
    g_cancel_wakes[g_cancel_wake_count].key = key;
    g_cancel_wakes[g_cancel_wake_count].write_fd = write_fd;
    g_cancel_wake_count++;
    lyric_global_unlock();
}

void lyric_cancel_wake_unregister(void* key, int32_t write_fd) {
    lyric_global_lock();
    for (size_t i = 0; i < g_cancel_wake_count; i++) {
        if (g_cancel_wakes[i].key == key && g_cancel_wakes[i].write_fd == write_fd) {
            g_cancel_wakes[i] = g_cancel_wakes[g_cancel_wake_count - 1];
            g_cancel_wake_count--;
            break;
        }
    }
    lyric_global_unlock();
}

void lyric_cancel_wake_signal(void* key) {
    lyric_global_lock();
    for (size_t i = 0; i < g_cancel_wake_count; i++) {
        if (g_cancel_wakes[i].key == key) {
            (void)lyric_sock_wake_pipe_signal(g_cancel_wakes[i].write_fd);
        }
    }
    lyric_global_unlock();
}
