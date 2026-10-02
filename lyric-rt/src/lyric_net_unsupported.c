/* lyric_net_unsupported.c — the lyric_sock_* / lyric_tls_* surface for targets
 * with no BSD sockets or dynamic loading (wasm32-wasi, docs/35 §5.3).  It
 * replaces lyric_tls.c in that build, which docs/61 §7 designs as a swappable
 * seam, so every `_kernel_native/tcp_host.l` / `tls_host.l` extern still
 * resolves and each call fails the way a real network failure does: -1 / NULL
 * with a recorded message the Lyric side surfaces as a typed error.
 */
#include "lyric_rt.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

static char last_err[128] = "";

static int32_t fail_sock(void) {
    snprintf(last_err, sizeof last_err, "TCP sockets are unavailable on this target (wasm32-wasi)");
    return -1;
}

static void* fail_tls(void) {
    snprintf(last_err, sizeof last_err, "TLS is unavailable on this target (wasm32-wasi has no sockets or dynamic loading)");
    return NULL;
}

int32_t lyric_sock_connect(const char* host, int32_t port) {
    (void)host; (void)port;
    return fail_sock();
}

int32_t lyric_sock_listen(const char* ip, int32_t port, int32_t backlog) {
    (void)ip; (void)port; (void)backlog;
    return fail_sock();
}

int32_t lyric_sock_local_port(int32_t fd) {
    (void)fd;
    return -1;
}

int32_t lyric_sock_accept(int32_t listen_fd) {
    (void)listen_fd;
    return fail_sock();
}

int32_t lyric_sock_accept_errno(void) {
    return ENOSYS;
}

/* 0: fatal, the caller's accept loop should end (there is no listener). */
int32_t lyric_sock_accept_error_class(void) {
    return 0;
}

int32_t lyric_sock_wake_pipe_new(int32_t* read_fd_out, int32_t* write_fd_out) {
    (void)read_fd_out; (void)write_fd_out;
    return fail_sock();
}

int32_t lyric_sock_wake_pipe_signal(int32_t write_fd) {
    (void)write_fd;
    return -1;
}

int32_t lyric_sock_accept_interruptible(int32_t listen_fd, int32_t wake_read_fd) {
    (void)listen_fd; (void)wake_read_fd;
    return fail_sock();
}

int32_t lyric_sock_set_timeouts(int32_t fd, int32_t timeout_ms) {
    (void)fd; (void)timeout_ms;
    return fail_sock();
}

int64_t lyric_sock_read(int32_t fd, uint8_t* buf, int64_t n) {
    (void)fd; (void)buf; (void)n;
    return fail_sock();
}

int64_t lyric_sock_write(int32_t fd, const uint8_t* buf, int64_t n) {
    (void)fd; (void)buf; (void)n;
    return fail_sock();
}

/* No fd ever exists, so any non-negative fd is invalid; a negative one is a
 * documented no-op. */
int32_t lyric_sock_close(int32_t fd) {
    return fd < 0 ? 0 : -1;
}

LyricList* lyric_sock_read_bytes(int32_t fd, int64_t max_bytes, int32_t* ok) {
    (void)fd;
    LyricList* list = lyric_list_new(0);
    if (max_bytes <= 0) {
        *ok = 1;
        return list;
    }
    fail_sock();
    *ok = 0;
    return list;
}

int64_t lyric_sock_write_bytes(int32_t fd, void* bytes_list) {
    (void)fd; (void)bytes_list;
    return fail_sock();
}

int32_t lyric_tls_available(void) {
    return 0;
}

void* lyric_tls_client_new(const char* ca_pem, int32_t min_version, int32_t insecure) {
    (void)ca_pem; (void)min_version; (void)insecure;
    return fail_tls();
}

void* lyric_tls_client_new_additive(const char* ca_pem, int32_t min_version, int32_t insecure) {
    (void)ca_pem; (void)min_version; (void)insecure;
    return fail_tls();
}

int32_t lyric_tls_client_set_identity(void* client_ctx, const char* cert_pem, const char* key_pem) {
    (void)client_ctx; (void)cert_pem; (void)key_pem;
    fail_tls();
    return -1;
}

void* lyric_tls_client_connect(void* client_ctx, int32_t fd, const char* sni_host, const char* alpn_csv) {
    (void)client_ctx; (void)fd; (void)sni_host; (void)alpn_csv;
    return fail_tls();
}

void* lyric_tls_server_new(const char* cert_pem, const char* key_pem, int32_t min_version,
                           const char* client_ca_pem, int32_t require_client_cert,
                           const char* alpn_csv) {
    (void)cert_pem; (void)key_pem; (void)min_version; (void)client_ca_pem;
    (void)require_client_cert; (void)alpn_csv;
    return fail_tls();
}

void* lyric_tls_server_accept(void* server_ctx, int32_t fd) {
    (void)server_ctx; (void)fd;
    return fail_tls();
}

int64_t lyric_tls_read(void* conn, uint8_t* buf, int64_t n) {
    (void)conn; (void)buf; (void)n;
    fail_tls();
    return -1;
}

int64_t lyric_tls_write(void* conn, const uint8_t* buf, int64_t n) {
    (void)conn; (void)buf; (void)n;
    fail_tls();
    return -1;
}

LyricList* lyric_tls_read_bytes(void* conn, int64_t max_bytes, int32_t* ok) {
    (void)conn;
    LyricList* list = lyric_list_new(0);
    if (max_bytes <= 0) {
        *ok = 1;
        return list;
    }
    fail_tls();
    *ok = 0;
    return list;
}

int64_t lyric_tls_write_bytes(void* conn, void* bytes_list) {
    (void)conn; (void)bytes_list;
    fail_tls();
    return -1;
}

int32_t lyric_tls_alpn(void* conn, char* out, int32_t out_cap) {
    (void)conn;
    if (out_cap > 0) out[0] = '\0';
    return 0;
}

void lyric_tls_shutdown(void* conn) {
    (void)conn;
}

void lyric_tls_free(void* conn) {
    (void)conn;
}

void lyric_tls_ctx_free(void* ctx) {
    (void)ctx;
}

int32_t lyric_tls_last_error(char* out, int32_t out_cap) {
    if (out_cap <= 0) return 0;
    size_t n = strlen(last_err);
    if (n >= (size_t)out_cap) n = (size_t)out_cap - 1;
    memcpy(out, last_err, n);
    out[n] = '\0';
    return (int32_t)n;
}

int32_t lyric_tls_validate_cert_pem(const char* cert_pem) {
    (void)cert_pem;
    fail_tls();
    return 0;
}

int32_t lyric_tls_validate_key_pem(const char* key_pem) {
    (void)key_pem;
    fail_tls();
    return 0;
}

int32_t lyric_tls_validate_identity_pem(const char* cert_pem, const char* key_pem) {
    (void)cert_pem; (void)key_pem;
    fail_tls();
    return 0;
}

LyricString* lyric_tls_last_error_string(void) {
    return lyric_string_from_literal((const uint8_t*)last_err, (int64_t)strlen(last_err));
}

LyricString* lyric_tls_alpn_string(void* conn) {
    (void)conn;
    return lyric_string_from_literal((const uint8_t*)"", 0);
}
