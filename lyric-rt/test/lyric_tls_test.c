/* lyric_tls_test.c — real-OpenSSL loopback tests for the native TCP + TLS
 * transport seam (lyric_tls.c; epic #5874 phase 5, issue #5890).
 *
 * Run via `make -C lyric-rt test` (and, with -fsanitize=address, the
 * lyric_tls_test_asan variant, so a leaked SSL_CTX/SSL/fd fails the run).
 * Each TLS scenario drives a genuine client<->server handshake over a
 * loopback socket on two threads with an embedded test PKI (an EC CA, a
 * `localhost`/127.0.0.1 server leaf, and a client leaf), exercising: plain
 * byte round-trip, server-auth TLS + ALPN negotiation, mutual TLS accept,
 * mutual TLS reject (client presents no certificate), hostname-verification
 * rejection, and the insecure-skip-verify override.
 *
 * If OpenSSL 3.x cannot be dlopen'd (a build environment without libssl),
 * the TLS scenarios are skipped with a printed notice and the process still
 * exits 0 — the honest boundary, never a silent pass of untested code.
 */
#if defined(__linux__)
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <sys/socket.h>
#include <sys/time.h>

static int failures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                    \
        }                                                                  \
    } while (0)

/* ── Embedded test PKI (generated offline with `openssl`; see the PR) ──── */

static const char CA_CRT[] =
    "-----BEGIN CERTIFICATE-----\n"
    "MIIBiDCCAS2gAwIBAgIUa+UpO+C7R20rI5EBFHE/liAYeiswCgYIKoZIzj0EAwIw\n"
    "GDEWMBQGA1UEAwwNTHlyaWMgVGVzdCBDQTAgFw0yNjA3MTgxOTQ2MjRaGA8yMTI2\n"
    "MDYyNDE5NDYyNFowGDEWMBQGA1UEAwwNTHlyaWMgVGVzdCBDQTBZMBMGByqGSM49\n"
    "AgEGCCqGSM49AwEHA0IABOsG7U338C1RcPt/OL4O3ounT3ygztqag26oIgpLYCA5\n"
    "HVYYjOlEEKjUGJhBGcXzw0jpRQDMFCJGHtOMVcJ/enCjUzBRMB0GA1UdDgQWBBSU\n"
    "EMVcBV+x/jMMGEnxGJYtMHl6yTAfBgNVHSMEGDAWgBSUEMVcBV+x/jMMGEnxGJYt\n"
    "MHl6yTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQCCOWeAOliu\n"
    "Xj1/18e9zSHEUq+gjgwtWl5N/aGfwUIsqAIhAJ50wTwnR+83mTgInxVGy7Jbua7a\n"
    "bc4iHgt6W2u9CR9k\n"
    "-----END CERTIFICATE-----\n";

static const char SERVER_CRT[] =
    "-----BEGIN CERTIFICATE-----\n"
    "MIIBjjCCATSgAwIBAgIUdUB+lVYMzv9aImIC8blgtl9VikEwCgYIKoZIzj0EAwIw\n"
    "GDEWMBQGA1UEAwwNTHlyaWMgVGVzdCBDQTAgFw0yNjA3MTgxOTQ2MjRaGA8yMTI2\n"
    "MDYyNDE5NDYyNFowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYI\n"
    "KoZIzj0DAQcDQgAEMo21Zj5ZUUrALT8gSA1nupzAxi9RYgD41XgYmknmSNxY5hpa\n"
    "02KW7RjFrZYho3FjQwjhf+QssXdneFf+uIJiY6NeMFwwGgYDVR0RBBMwEYIJbG9j\n"
    "YWxob3N0hwR/AAABMB0GA1UdDgQWBBTv8kqnlNk2k2rm+6j+DL471IR2/jAfBgNV\n"
    "HSMEGDAWgBSUEMVcBV+x/jMMGEnxGJYtMHl6yTAKBggqhkjOPQQDAgNIADBFAiEA\n"
    "wQM23cqOw7M0G8ThjJ8aDDzfAJmgHM2/T4mfv0c1c9MCIHUelTrjNTDDiDCXjI3F\n"
    "LXnijJTPgm/DrWzfDHoMzD2l\n"
    "-----END CERTIFICATE-----\n";

static const char SERVER_KEY[] =
    "-----BEGIN PRIVATE KEY-----\n"
    "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgiqxrZ6ywX4KddmSt\n"
    "rmk/qY9bMTRjkRmANXEUmf9UUiGhRANCAAQyjbVmPllRSsAtPyBIDWe6nMDGL1Fi\n"
    "APjVeBiaSeZI3FjmGlrTYpbtGMWtliGjcWNDCOF/5Cyxd2d4V/64gmJj\n"
    "-----END PRIVATE KEY-----\n";

static const char CLIENT_CRT[] =
    "-----BEGIN CERTIFICATE-----\n"
    "MIIBLzCB1wIUdUB+lVYMzv9aImIC8blgtl9VikIwCgYIKoZIzj0EAwIwGDEWMBQG\n"
    "A1UEAwwNTHlyaWMgVGVzdCBDQTAgFw0yNjA3MTgxOTQ2MjRaGA8yMTI2MDYyNDE5\n"
    "NDYyNFowHDEaMBgGA1UEAwwRbHlyaWMtdGVzdC1jbGllbnQwWTATBgcqhkjOPQIB\n"
    "BggqhkjOPQMBBwNCAASd3zE8mkFLmJSIAY+7DtrPC8P5YmxEuDLkF+iQ4V4UcZqo\n"
    "w5QFHvSNU3H/l+GiwUZPDj6Vtb1QfjW57CDrb5obMAoGCCqGSM49BAMCA0cAMEQC\n"
    "IDvZWNuawAlkcFTzQwiJNrH2esyGsS0xXx0g8G1Pa16ZAiAtez4cY3edXYBK2NUE\n"
    "XFRFxntxwDw+tH0nSu02YuyDxg==\n"
    "-----END CERTIFICATE-----\n";

static const char CLIENT_KEY[] =
    "-----BEGIN PRIVATE KEY-----\n"
    "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgDk7Fx3GHeDogly+Q\n"
    "CLrpmCJmHmEvlxxMCwToLV6JSKehRANCAASd3zE8mkFLmJSIAY+7DtrPC8P5YmxE\n"
    "uDLkF+iQ4V4UcZqow5QFHvSNU3H/l+GiwUZPDj6Vtb1QfjW57CDrb5ob\n"
    "-----END PRIVATE KEY-----\n";

static const char REQUEST[] = "PING from lyric client";
static const char RESPONSE[] = "PONG from lyric server";

/* Bound the loopback I/O so a mishandshake can never hang the test. */
static void set_timeout(int fd) {
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

/* ── Plain (non-TLS) socket round-trip ────────────────────────────────── */

static void* plain_server(void* arg) {
    int listen_fd = *(int*)arg;
    int fd = lyric_sock_accept(listen_fd);
    if (fd < 0) return NULL;
    set_timeout(fd);
    uint8_t buf[128];
    int64_t n = lyric_sock_read(fd, buf, sizeof(buf));
    if (n > 0) lyric_sock_write(fd, buf, n); /* echo */
    lyric_sock_close(fd);
    return NULL;
}

static void test_plain_roundtrip(void) {
    int listen_fd = lyric_sock_listen("127.0.0.1", 0, 16);
    CHECK(listen_fd >= 0);
    int port = lyric_sock_local_port(listen_fd);
    CHECK(port > 0);

    pthread_t th;
    pthread_create(&th, NULL, plain_server, &listen_fd);

    int fd = lyric_sock_connect("127.0.0.1", port);
    CHECK(fd >= 0);
    set_timeout(fd);
    CHECK(lyric_sock_write(fd, (const uint8_t*)REQUEST, (int64_t)strlen(REQUEST)) ==
          (int64_t)strlen(REQUEST));
    uint8_t buf[128];
    int64_t n = lyric_sock_read(fd, buf, sizeof(buf));
    CHECK(n == (int64_t)strlen(REQUEST));
    CHECK(memcmp(buf, REQUEST, (size_t)n) == 0);
    lyric_sock_close(fd);

    pthread_join(th, NULL);
    lyric_sock_close(listen_fd);
}

/* ── TLS scenario harness ─────────────────────────────────────────────── */

typedef struct {
    int listen_fd;
    void* server_ctx;
    int accept_ok;       /* server handshake succeeded */
    int echoed;          /* server read + wrote the request back */
    char alpn[32];       /* server-side negotiated ALPN */
} tls_server_arg;

static void* tls_server(void* p) {
    tls_server_arg* a = (tls_server_arg*)p;
    int fd = lyric_sock_accept(a->listen_fd);
    if (fd < 0) return NULL;
    set_timeout(fd);
    void* conn = lyric_tls_server_accept(a->server_ctx, fd);
    if (!conn) {
        a->accept_ok = 0;
        lyric_sock_close(fd);
        return NULL;
    }
    a->accept_ok = 1;
    lyric_tls_alpn(conn, a->alpn, sizeof(a->alpn));
    uint8_t buf[256];
    int64_t n = lyric_tls_read(conn, buf, sizeof(buf));
    if (n > 0) {
        lyric_tls_write(conn, (const uint8_t*)RESPONSE, (int64_t)strlen(RESPONSE));
        a->echoed = 1;
    }
    lyric_tls_shutdown(conn);
    lyric_tls_free(conn);
    lyric_sock_close(fd);
    return NULL;
}

/* Drive one full client<->server TLS scenario.  Returns 1 iff the client
 * handshake succeeded; writes the client-side negotiated ALPN into
 * `client_alpn` and the round-trip success into `*rt_ok`. */
static int run_tls_scenario(void* server_ctx, void* client_ctx, const char* sni,
                            const char* client_alpn_csv, char* client_alpn, int* rt_ok,
                            tls_server_arg* srv_out) {
    *rt_ok = 0;
    if (client_alpn) client_alpn[0] = '\0';

    int listen_fd = lyric_sock_listen("127.0.0.1", 0, 16);
    CHECK(listen_fd >= 0);
    int port = lyric_sock_local_port(listen_fd);
    CHECK(port > 0);

    tls_server_arg sa;
    memset(&sa, 0, sizeof(sa));
    sa.listen_fd = listen_fd;
    sa.server_ctx = server_ctx;

    pthread_t th;
    pthread_create(&th, NULL, tls_server, &sa);

    int fd = lyric_sock_connect("127.0.0.1", port);
    CHECK(fd >= 0);
    set_timeout(fd);
    void* conn = lyric_tls_client_connect(client_ctx, fd, sni, client_alpn_csv);
    int client_ok = conn != NULL;
    if (conn) {
        if (client_alpn) lyric_tls_alpn(conn, client_alpn, 32);
        if (lyric_tls_write(conn, (const uint8_t*)REQUEST, (int64_t)strlen(REQUEST)) > 0) {
            uint8_t buf[256];
            int64_t n = lyric_tls_read(conn, buf, sizeof(buf));
            if (n == (int64_t)strlen(RESPONSE) && memcmp(buf, RESPONSE, (size_t)n) == 0) {
                *rt_ok = 1;
            }
        }
        lyric_tls_shutdown(conn);
        lyric_tls_free(conn);
    }
    lyric_sock_close(fd);
    pthread_join(th, NULL);
    lyric_sock_close(listen_fd);
    if (srv_out) *srv_out = sa;
    return client_ok;
}

static void test_tls_server_auth(void) {
    void* server = lyric_tls_server_new(SERVER_CRT, SERVER_KEY, 12, "", 0, "http/1.1");
    CHECK(server != NULL);
    void* client = lyric_tls_client_new(CA_CRT, 0);
    CHECK(client != NULL);
    if (server && client) {
        char calpn[32];
        int rt = 0;
        tls_server_arg srv;
        int ok = run_tls_scenario(server, client, "localhost", "h2,http/1.1", calpn, &rt, &srv);
        CHECK(ok == 1);
        CHECK(rt == 1);
        CHECK(srv.accept_ok == 1);
        CHECK(srv.echoed == 1);
        CHECK(strcmp(calpn, "http/1.1") == 0);       /* client-side negotiated */
        CHECK(strcmp(srv.alpn, "http/1.1") == 0);    /* server-side negotiated */
    }
    lyric_tls_ctx_free(server);
    lyric_tls_ctx_free(client);
}

static void test_tls_tls13_floor(void) {
    void* server = lyric_tls_server_new(SERVER_CRT, SERVER_KEY, 13, "", 0, "http/1.1");
    CHECK(server != NULL);
    void* client = lyric_tls_client_new(CA_CRT, 0);
    CHECK(client != NULL);
    if (server && client) {
        char calpn[32];
        int rt = 0;
        int ok = run_tls_scenario(server, client, "localhost", "http/1.1", calpn, &rt, NULL);
        CHECK(ok == 1);
        CHECK(rt == 1);
    }
    lyric_tls_ctx_free(server);
    lyric_tls_ctx_free(client);
}

static void test_mtls_accept(void) {
    void* server = lyric_tls_server_new(SERVER_CRT, SERVER_KEY, 12, CA_CRT, 1, "http/1.1");
    CHECK(server != NULL);
    void* client = lyric_tls_client_new(CA_CRT, 0);
    CHECK(client != NULL);
    if (server && client) {
        CHECK(lyric_tls_client_set_identity(client, CLIENT_CRT, CLIENT_KEY) == 0);
        char calpn[32];
        int rt = 0;
        tls_server_arg srv;
        int ok = run_tls_scenario(server, client, "localhost", "http/1.1", calpn, &rt, &srv);
        CHECK(ok == 1);
        CHECK(rt == 1);
        CHECK(srv.accept_ok == 1);
    }
    lyric_tls_ctx_free(server);
    lyric_tls_ctx_free(client);
}

static void test_mtls_reject_no_client_cert(void) {
    void* server = lyric_tls_server_new(SERVER_CRT, SERVER_KEY, 12, CA_CRT, 1, "http/1.1");
    CHECK(server != NULL);
    /* Client presents NO certificate — the server requires one. */
    void* client = lyric_tls_client_new(CA_CRT, 0);
    CHECK(client != NULL);
    if (server && client) {
        char calpn[32];
        int rt = 0;
        tls_server_arg srv;
        int ok = run_tls_scenario(server, client, "localhost", "http/1.1", calpn, &rt, &srv);
        (void)ok; /* TLS 1.3: the client's handshake returns before the server
                   * validates the client cert (client auth is the last flight),
                   * so `ok` may be 1 with the rejection surfacing on the next
                   * read.  The guarantees that hold on every version are that the
                   * server refuses the peer and no data round-trips. */
        CHECK(rt == 0);
        CHECK(srv.accept_ok == 0); /* server refused the certificate-less peer */
    }
    lyric_tls_ctx_free(server);
    lyric_tls_ctx_free(client);
}

static void test_hostname_mismatch_rejected(void) {
    void* server = lyric_tls_server_new(SERVER_CRT, SERVER_KEY, 12, "", 0, "http/1.1");
    CHECK(server != NULL);
    void* client = lyric_tls_client_new(CA_CRT, 0);
    CHECK(client != NULL);
    if (server && client) {
        char calpn[32];
        int rt = 0;
        /* Chains to the CA, but the cert is for localhost, not example.com. */
        int ok = run_tls_scenario(server, client, "example.com", "http/1.1", calpn, &rt, NULL);
        CHECK(ok == 0);
        CHECK(rt == 0);
    }
    lyric_tls_ctx_free(server);
    lyric_tls_ctx_free(client);
}

static void test_insecure_skip_verify(void) {
    void* server = lyric_tls_server_new(SERVER_CRT, SERVER_KEY, 12, "", 0, "http/1.1");
    CHECK(server != NULL);
    /* No CA, insecure=1: a hostname the cert does not cover still connects. */
    void* client = lyric_tls_client_new("", 1);
    CHECK(client != NULL);
    if (server && client) {
        char calpn[32];
        int rt = 0;
        int ok = run_tls_scenario(server, client, "not-in-cert.example", "http/1.1", calpn, &rt, NULL);
        CHECK(ok == 1);
        CHECK(rt == 1);
    }
    lyric_tls_ctx_free(server);
    lyric_tls_ctx_free(client);
}

int main(void) {
    test_plain_roundtrip();

    if (!lyric_tls_available()) {
        char err[256];
        lyric_tls_last_error(err, sizeof(err));
        printf("lyric_tls_test: OpenSSL 3.x unavailable (%s); TLS scenarios skipped\n", err);
        printf(failures == 0 ? "lyric_tls_test: plain-socket tests passed\n"
                             : "lyric_tls_test: FAILURES\n");
        return failures == 0 ? 0 : 1;
    }

    test_tls_server_auth();
    test_tls_tls13_floor();
    test_mtls_accept();
    test_mtls_reject_no_client_cert();
    test_hostname_mismatch_rejected();
    test_insecure_skip_verify();

    if (failures == 0) {
        printf("lyric_tls_test: all tests passed\n");
        return 0;
    }
    fprintf(stderr, "lyric_tls_test: %d failure(s)\n", failures);
    return 1;
}
