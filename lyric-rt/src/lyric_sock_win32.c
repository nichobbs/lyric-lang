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

int32_t lyric_sock_close(int32_t fd) {
    if (fd < 0) return 0;
    return closesocket(to_socket(fd)) == 0 ? 0 : -1;
}

/* `how` uses the POSIX values (0 read, 1 write, 2 both), which equal
 * SD_RECEIVE, SD_SEND and SD_BOTH. */
int32_t lyric_sock_shutdown(int32_t fd, int32_t how) {
    return shutdown(to_socket(fd), how) == 0 ? 0 : -1;
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
        int got = recv(to_socket(fd), (char*)buf, want, 0);
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

int64_t lyric_sock_write(int32_t fd, const uint8_t* buf, int64_t n) {
    int64_t off = 0;
    while (off < n) {
        int64_t left = n - off;
        int chunk = left > INT32_MAX ? INT32_MAX : (int)left;
        int w = send(to_socket(fd), (const char*)buf + off, chunk, 0);
        if (w < 0) {
            int e = WSAGetLastError();
            if (e == WSAEINTR) continue;
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
