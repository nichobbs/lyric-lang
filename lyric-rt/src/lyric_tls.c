/* lyric_tls.c — native-target TCP socket + TLS transport seam for the
 * sans-IO Std.HttpEngine (docs/61 §7, D128 decision 10; epic #5874 phase 5,
 * issue #5890).
 *
 * TWO layers:
 *   * lyric_sock_* — a blocking POSIX socket transport (connect / listen /
 *     accept / read / write / close).  No OpenSSL dependency; always
 *     available.
 *   * lyric_tls_* — a narrow TLS seam over OpenSSL 3.x, loaded DYNAMICALLY
 *     with dlopen/dlsym on first use.  lyric_rt.a therefore has NO link-time
 *     dependency on libssl/libcrypto: a native binary that never opens a TLS
 *     connection never loads OpenSSL, and the seam can be re-pointed at
 *     mbedTLS (static/musl builds) by swapping THIS FILE alone — no Lyric
 *     code changes (the swappable-seam intent of D128 decision 10).
 *
 * The OpenSSL symbols are declared here as a hand-rolled function-pointer
 * table over opaque struct pointers, so this translation unit compiles with
 * ZERO OpenSSL build-time dependency (no openssl headers needed) — the
 * runtime archive builds on a box without libssl-dev.  Only the 3.x ABI is
 * targeted (D128 decision 10).
 *
 * All handles are RAW malloc'd resources, freed explicitly (the
 * lyric_process_* op discipline), NOT ARC objects.  The _kernel_native/
 * Lyric twin wraps each in an opaque type whose destructor calls the
 * matching free — that is where docs/61 §7 item 4's ARC-managed lifetime
 * lives.
 */
#if defined(__linux__)
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

/* ── Thread-local last-error diagnostics ──────────────────────────────── */

static _Thread_local char g_err[256];

static void set_err(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof(g_err), fmt, ap);
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

/* ── POSIX socket transport (no OpenSSL) ──────────────────────────────── */

int32_t lyric_sock_close(int32_t fd) {
    if (fd < 0) return 0;
    /* close(2) is not retried on EINTR: the fd is released regardless on
     * Linux/macOS, so retrying risks closing an unrelated reused fd — the
     * same reasoning lyric_file_close documents. */
    return close(fd) == 0 ? 0 : -1;
}

int32_t lyric_sock_connect(const char* host, int32_t port) {
    if (!host || port < 0 || port > 65535) {
        set_err("invalid host/port");
        return -1;
    }
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", (int)port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo* res = NULL;
    int gai = getaddrinfo(host, portstr, &hints, &res);
    if (gai != 0) {
        set_err("resolve %s: %s", host, gai_strerror(gai));
        return -1;
    }

    int fd = -1;
    int last_errno = 0;
    for (struct addrinfo* ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            last_errno = errno;
            continue;
        }
        int rc;
        do {
            rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        } while (rc < 0 && errno == EINTR);
        if (rc == 0) break; /* connected */
        last_errno = errno;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        set_err("connect %s:%d: %s", host, (int)port,
                last_errno ? strerror(last_errno) : "no usable address");
        return -1;
    }
    return (int32_t)fd;
}

int32_t lyric_sock_listen(const char* ip, int32_t port, int32_t backlog) {
    if (!ip || port < 0 || port > 65535) {
        set_err("invalid bind address/port");
        return -1;
    }
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", (int)port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE | AI_NUMERICHOST; /* ip literal only */

    struct addrinfo* res = NULL;
    int gai = getaddrinfo(ip, portstr, &hints, &res);
    if (gai != 0) {
        set_err("bind address %s: %s", ip, gai_strerror(gai));
        return -1;
    }

    int fd = -1;
    int last_errno = 0;
    for (struct addrinfo* ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            last_errno = errno;
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 &&
            listen(fd, backlog > 0 ? backlog : 128) == 0) {
            break; /* bound + listening */
        }
        last_errno = errno;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        set_err("listen %s:%d: %s", ip, (int)port,
                last_errno ? strerror(last_errno) : "no usable address");
        return -1;
    }
    return (int32_t)fd;
}

int32_t lyric_sock_local_port(int32_t fd) {
    struct sockaddr_storage ss;
    socklen_t len = sizeof(ss);
    if (getsockname(fd, (struct sockaddr*)&ss, &len) != 0) {
        set_err("getsockname: %s", strerror(errno));
        return -1;
    }
    if (ss.ss_family == AF_INET) {
        return (int32_t)ntohs(((struct sockaddr_in*)&ss)->sin_port);
    }
    if (ss.ss_family == AF_INET6) {
        return (int32_t)ntohs(((struct sockaddr_in6*)&ss)->sin6_port);
    }
    set_err("getsockname: unknown address family");
    return -1;
}

int32_t lyric_sock_accept(int32_t listen_fd) {
    int fd;
    do {
        fd = accept(listen_fd, NULL, NULL);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        set_err("accept: %s", strerror(errno));
        return -1;
    }
    return (int32_t)fd;
}

int64_t lyric_sock_read(int32_t fd, uint8_t* buf, int64_t n) {
    if (n <= 0) return 0;
    ssize_t got;
    do {
        got = read(fd, buf, (size_t)n);
    } while (got < 0 && errno == EINTR);
    if (got < 0) {
        set_err("read: %s", strerror(errno));
        return -1;
    }
    return (int64_t)got;
}

int64_t lyric_sock_write(int32_t fd, const uint8_t* buf, int64_t n) {
    int64_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, buf + off, (size_t)(n - off));
        if (w < 0) {
            if (errno == EINTR) continue;
            set_err("write: %s", strerror(errno));
            return -1;
        }
        if (w == 0) {
            set_err("write: no progress");
            return -1;
        }
        off += w;
    }
    return n;
}

/* ── OpenSSL 3.x dynamic binding ──────────────────────────────────────── */

/* Opaque OpenSSL types (we only ever hold pointers). */
typedef struct ossl_method ossl_method;
typedef struct ossl_ssl_ctx ossl_ssl_ctx;
typedef struct ossl_ssl ossl_ssl;
typedef struct ossl_x509 ossl_x509;
typedef struct ossl_evp_pkey ossl_evp_pkey;
typedef struct ossl_bio ossl_bio;
typedef struct ossl_x509_store ossl_x509_store;
typedef int (*ossl_pw_cb)(char*, int, int, void*);
typedef int (*ossl_alpn_cb)(ossl_ssl*, const unsigned char**, unsigned char*,
                            const unsigned char*, unsigned int, void*);

/* ABI constants (OpenSSL 3.x, stable). */
#define OSSL_TLS1_2_VERSION 0x0303
#define OSSL_TLS1_3_VERSION 0x0304
#define OSSL_SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define OSSL_TLSEXT_NAMETYPE_host_name 0
#define OSSL_SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define OSSL_SSL_VERIFY_NONE 0x00
#define OSSL_SSL_VERIFY_PEER 0x01
#define OSSL_SSL_VERIFY_FAIL_IF_NO_PEER_CERT 0x02
#define OSSL_SSL_ERROR_WANT_READ 2
#define OSSL_SSL_ERROR_WANT_WRITE 3
#define OSSL_SSL_ERROR_ZERO_RETURN 6
#define OSSL_X509_V_OK 0
#define OSSL_SSL_TLSEXT_ERR_OK 0
#define OSSL_SSL_TLSEXT_ERR_NOACK 3

struct ossl_fns {
    const ossl_method* (*TLS_client_method)(void);
    const ossl_method* (*TLS_server_method)(void);
    ossl_ssl_ctx* (*SSL_CTX_new)(const ossl_method*);
    void (*SSL_CTX_free)(ossl_ssl_ctx*);
    long (*SSL_CTX_ctrl)(ossl_ssl_ctx*, int, long, void*);
    int (*SSL_CTX_set_default_verify_paths)(ossl_ssl_ctx*);
    ossl_x509_store* (*SSL_CTX_get_cert_store)(const ossl_ssl_ctx*);
    void (*SSL_CTX_set_verify)(ossl_ssl_ctx*, int, void*);
    int (*SSL_CTX_use_certificate)(ossl_ssl_ctx*, ossl_x509*);
    int (*SSL_CTX_use_PrivateKey)(ossl_ssl_ctx*, ossl_evp_pkey*);
    int (*SSL_CTX_check_private_key)(const ossl_ssl_ctx*);
    int (*SSL_CTX_set_alpn_protos)(ossl_ssl_ctx*, const unsigned char*, unsigned int);
    void (*SSL_CTX_set_alpn_select_cb)(ossl_ssl_ctx*, ossl_alpn_cb, void*);
    ossl_ssl* (*SSL_new)(ossl_ssl_ctx*);
    void (*SSL_free)(ossl_ssl*);
    int (*SSL_set_fd)(ossl_ssl*, int);
    long (*SSL_ctrl)(ossl_ssl*, int, long, void*);
    int (*SSL_set1_host)(ossl_ssl*, const char*);
    int (*SSL_set_alpn_protos)(ossl_ssl*, const unsigned char*, unsigned int);
    int (*SSL_connect)(ossl_ssl*);
    int (*SSL_accept)(ossl_ssl*);
    int (*SSL_read)(ossl_ssl*, void*, int);
    int (*SSL_write)(ossl_ssl*, const void*, int);
    int (*SSL_shutdown)(ossl_ssl*);
    int (*SSL_get_error)(const ossl_ssl*, int);
    long (*SSL_get_verify_result)(const ossl_ssl*);
    void (*SSL_get0_alpn_selected)(const ossl_ssl*, const unsigned char**, unsigned int*);
    int (*SSL_select_next_proto)(unsigned char**, unsigned char*, const unsigned char*,
                                 unsigned int, const unsigned char*, unsigned int);
    /* libcrypto */
    ossl_bio* (*BIO_new_mem_buf)(const void*, int);
    int (*BIO_free)(ossl_bio*);
    ossl_x509* (*PEM_read_bio_X509)(ossl_bio*, ossl_x509**, ossl_pw_cb, void*);
    void (*X509_free)(ossl_x509*);
    int (*X509_STORE_add_cert)(ossl_x509_store*, ossl_x509*);
    ossl_evp_pkey* (*PEM_read_bio_PrivateKey)(ossl_bio*, ossl_evp_pkey**, ossl_pw_cb, void*);
    void (*EVP_PKEY_free)(ossl_evp_pkey*);
    unsigned long (*ERR_get_error)(void);
    void (*ERR_error_string_n)(unsigned long, char*, size_t);
};

static struct ossl_fns O;
static int g_tls_loaded = 0;   /* 1 = symbols resolved, -1 = load failed */
static pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;

static void* dlopen_any(const char* const* names) {
    for (int i = 0; names[i]; i++) {
        /* RTLD_LOCAL: every symbol is resolved explicitly via dlsym below, so
         * there is no need to widen the process's global symbol namespace with
         * libssl/libcrypto exports. */
        void* h = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
        if (h) return h;
    }
    return NULL;
}

/* Resolve one symbol; on failure record it and flip *ok to 0. */
static void* resolve(void* h, const char* name, int* ok) {
    void* p = dlsym(h, name);
    if (!p) {
        if (*ok) set_err("OpenSSL symbol not found: %s", name);
        *ok = 0;
    }
    return p;
}

static void load_openssl(void) {
#if defined(__APPLE__)
    static const char* const crypto_names[] = {"libcrypto.3.dylib", "libcrypto.dylib", NULL};
    static const char* const ssl_names[] = {"libssl.3.dylib", "libssl.dylib", NULL};
#else
    static const char* const crypto_names[] = {"libcrypto.so.3", "libcrypto.so", NULL};
    static const char* const ssl_names[] = {"libssl.so.3", "libssl.so", NULL};
#endif
    void* hc = dlopen_any(crypto_names);
    void* hs = dlopen_any(ssl_names);
    if (!hc || !hs) {
        set_err("cannot load OpenSSL 3.x (libssl/libcrypto not found)");
        g_tls_loaded = -1;
        return;
    }
    int ok = 1;
    O.TLS_client_method = (const ossl_method* (*)(void))resolve(hs, "TLS_client_method", &ok);
    O.TLS_server_method = (const ossl_method* (*)(void))resolve(hs, "TLS_server_method", &ok);
    O.SSL_CTX_new = (ossl_ssl_ctx* (*)(const ossl_method*))resolve(hs, "SSL_CTX_new", &ok);
    O.SSL_CTX_free = (void (*)(ossl_ssl_ctx*))resolve(hs, "SSL_CTX_free", &ok);
    O.SSL_CTX_ctrl = (long (*)(ossl_ssl_ctx*, int, long, void*))resolve(hs, "SSL_CTX_ctrl", &ok);
    O.SSL_CTX_set_default_verify_paths =
        (int (*)(ossl_ssl_ctx*))resolve(hs, "SSL_CTX_set_default_verify_paths", &ok);
    O.SSL_CTX_get_cert_store =
        (ossl_x509_store* (*)(const ossl_ssl_ctx*))resolve(hs, "SSL_CTX_get_cert_store", &ok);
    O.SSL_CTX_set_verify = (void (*)(ossl_ssl_ctx*, int, void*))resolve(hs, "SSL_CTX_set_verify", &ok);
    O.SSL_CTX_use_certificate =
        (int (*)(ossl_ssl_ctx*, ossl_x509*))resolve(hs, "SSL_CTX_use_certificate", &ok);
    O.SSL_CTX_use_PrivateKey =
        (int (*)(ossl_ssl_ctx*, ossl_evp_pkey*))resolve(hs, "SSL_CTX_use_PrivateKey", &ok);
    O.SSL_CTX_check_private_key =
        (int (*)(const ossl_ssl_ctx*))resolve(hs, "SSL_CTX_check_private_key", &ok);
    O.SSL_CTX_set_alpn_protos =
        (int (*)(ossl_ssl_ctx*, const unsigned char*, unsigned int))resolve(hs, "SSL_CTX_set_alpn_protos", &ok);
    O.SSL_CTX_set_alpn_select_cb =
        (void (*)(ossl_ssl_ctx*, ossl_alpn_cb, void*))resolve(hs, "SSL_CTX_set_alpn_select_cb", &ok);
    O.SSL_new = (ossl_ssl* (*)(ossl_ssl_ctx*))resolve(hs, "SSL_new", &ok);
    O.SSL_free = (void (*)(ossl_ssl*))resolve(hs, "SSL_free", &ok);
    O.SSL_set_fd = (int (*)(ossl_ssl*, int))resolve(hs, "SSL_set_fd", &ok);
    O.SSL_ctrl = (long (*)(ossl_ssl*, int, long, void*))resolve(hs, "SSL_ctrl", &ok);
    O.SSL_set1_host = (int (*)(ossl_ssl*, const char*))resolve(hs, "SSL_set1_host", &ok);
    O.SSL_set_alpn_protos =
        (int (*)(ossl_ssl*, const unsigned char*, unsigned int))resolve(hs, "SSL_set_alpn_protos", &ok);
    O.SSL_connect = (int (*)(ossl_ssl*))resolve(hs, "SSL_connect", &ok);
    O.SSL_accept = (int (*)(ossl_ssl*))resolve(hs, "SSL_accept", &ok);
    O.SSL_read = (int (*)(ossl_ssl*, void*, int))resolve(hs, "SSL_read", &ok);
    O.SSL_write = (int (*)(ossl_ssl*, const void*, int))resolve(hs, "SSL_write", &ok);
    O.SSL_shutdown = (int (*)(ossl_ssl*))resolve(hs, "SSL_shutdown", &ok);
    O.SSL_get_error = (int (*)(const ossl_ssl*, int))resolve(hs, "SSL_get_error", &ok);
    O.SSL_get_verify_result = (long (*)(const ossl_ssl*))resolve(hs, "SSL_get_verify_result", &ok);
    O.SSL_get0_alpn_selected =
        (void (*)(const ossl_ssl*, const unsigned char**, unsigned int*))resolve(hs, "SSL_get0_alpn_selected", &ok);
    O.SSL_select_next_proto =
        (int (*)(unsigned char**, unsigned char*, const unsigned char*, unsigned int,
                 const unsigned char*, unsigned int))resolve(hs, "SSL_select_next_proto", &ok);
    O.BIO_new_mem_buf = (ossl_bio* (*)(const void*, int))resolve(hc, "BIO_new_mem_buf", &ok);
    O.BIO_free = (int (*)(ossl_bio*))resolve(hc, "BIO_free", &ok);
    O.PEM_read_bio_X509 =
        (ossl_x509* (*)(ossl_bio*, ossl_x509**, ossl_pw_cb, void*))resolve(hc, "PEM_read_bio_X509", &ok);
    O.X509_free = (void (*)(ossl_x509*))resolve(hc, "X509_free", &ok);
    O.X509_STORE_add_cert = (int (*)(ossl_x509_store*, ossl_x509*))resolve(hc, "X509_STORE_add_cert", &ok);
    O.PEM_read_bio_PrivateKey =
        (ossl_evp_pkey* (*)(ossl_bio*, ossl_evp_pkey**, ossl_pw_cb, void*))resolve(hc, "PEM_read_bio_PrivateKey", &ok);
    O.EVP_PKEY_free = (void (*)(ossl_evp_pkey*))resolve(hc, "EVP_PKEY_free", &ok);
    O.ERR_get_error = (unsigned long (*)(void))resolve(hc, "ERR_get_error", &ok);
    O.ERR_error_string_n = (void (*)(unsigned long, char*, size_t))resolve(hc, "ERR_error_string_n", &ok);

    g_tls_loaded = ok ? 1 : -1;
}

static int tls_ready(void) {
    pthread_once(&g_tls_once, load_openssl);
    return g_tls_loaded == 1;
}

int32_t lyric_tls_available(void) {
    return tls_ready() ? 1 : 0;
}

/* Format the current OpenSSL error queue into last_error, prefixed with a
 * caller-supplied context.  Drains the queue. */
static void set_ossl_err(const char* ctx) {
    unsigned long e = O.ERR_get_error ? O.ERR_get_error() : 0;
    if (e == 0) {
        set_err("%s", ctx);
        return;
    }
    char ebuf[160];
    O.ERR_error_string_n(e, ebuf, sizeof(ebuf));
    set_err("%s: %s", ctx, ebuf);
    /* drain the rest of the queue */
    while (O.ERR_get_error() != 0) {
    }
}

/* ── Context wrapper (owns the SSL_CTX + the server ALPN wire list) ────── */

typedef struct {
    ossl_ssl_ctx* ctx;
    int insecure;            /* client: verification disabled */
    unsigned char* alpn_wire; /* server: length-prefixed protocol list */
    unsigned int alpn_len;
} lyric_tls_ctx_t;

/* Convert "h2,http/1.1" into the ALPN wire format (each proto: 1 length
 * byte + bytes).  Returns a malloc'd buffer + length via out params, or
 * leaves them NULL/0 when csv is empty.  Returns 0 on success, -1 on a
 * malformed entry (empty or >255 bytes). */
static int build_alpn_wire(const char* csv, unsigned char** out, unsigned int* out_len) {
    *out = NULL;
    *out_len = 0;
    if (!csv || csv[0] == '\0') return 0;
    size_t total = strlen(csv) + 8;
    unsigned char* buf = (unsigned char*)malloc(total);
    if (!buf) return -1;
    unsigned int w = 0;
    const char* p = csv;
    while (*p) {
        const char* comma = strchr(p, ',');
        size_t seg = comma ? (size_t)(comma - p) : strlen(p);
        if (seg == 0 || seg > 255) {
            free(buf);
            return -1;
        }
        buf[w++] = (unsigned char)seg;
        memcpy(buf + w, p, seg);
        w += (unsigned int)seg;
        if (!comma) break;
        p = comma + 1;
    }
    *out = buf;
    *out_len = w;
    return 0;
}

/* Load the FIRST certificate from a PEM block (the leaf); returns NULL on
 * failure.  Intermediate-chain certs beyond the leaf are a documented
 * follow-on (N-TLS server-chain item). */
static ossl_x509* read_cert(const char* pem) {
    ossl_bio* bio = O.BIO_new_mem_buf(pem, -1);
    if (!bio) return NULL;
    ossl_x509* x = O.PEM_read_bio_X509(bio, NULL, NULL, NULL);
    O.BIO_free(bio);
    return x;
}

static ossl_evp_pkey* read_key(const char* pem) {
    ossl_bio* bio = O.BIO_new_mem_buf(pem, -1);
    if (!bio) return NULL;
    ossl_evp_pkey* k = O.PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    O.BIO_free(bio);
    return k;
}

/* Add a PEM CA (its first cert) to a context's trust store.  0 / -1. */
static int add_ca(ossl_ssl_ctx* ctx, const char* ca_pem) {
    ossl_x509* ca = read_cert(ca_pem);
    if (!ca) {
        set_ossl_err("parse CA certificate");
        return -1;
    }
    ossl_x509_store* store = O.SSL_CTX_get_cert_store(ctx);
    int rc = O.X509_STORE_add_cert(store, ca);
    O.X509_free(ca); /* store took its own ref */
    if (rc != 1) {
        set_ossl_err("add CA certificate to trust store");
        return -1;
    }
    return 0;
}

/* Install cert_pem (leaf) + key_pem (PKCS#8) on a context and verify they
 * match.  0 / -1. */
static int use_identity(ossl_ssl_ctx* ctx, const char* cert_pem, const char* key_pem) {
    ossl_x509* cert = read_cert(cert_pem);
    if (!cert) {
        set_ossl_err("parse certificate");
        return -1;
    }
    int rc = O.SSL_CTX_use_certificate(ctx, cert);
    O.X509_free(cert);
    if (rc != 1) {
        set_ossl_err("use certificate");
        return -1;
    }
    ossl_evp_pkey* key = read_key(key_pem);
    if (!key) {
        set_ossl_err("parse private key (only unencrypted PKCS#8 is supported)");
        return -1;
    }
    rc = O.SSL_CTX_use_PrivateKey(ctx, key);
    O.EVP_PKEY_free(key);
    if (rc != 1) {
        set_ossl_err("use private key");
        return -1;
    }
    if (O.SSL_CTX_check_private_key(ctx) != 1) {
        set_ossl_err("certificate/key mismatch");
        return -1;
    }
    return 0;
}

static int set_min_version(ossl_ssl_ctx* ctx, int32_t min_version) {
    long v = (min_version >= 13) ? OSSL_TLS1_3_VERSION : OSSL_TLS1_2_VERSION;
    if (O.SSL_CTX_ctrl(ctx, OSSL_SSL_CTRL_SET_MIN_PROTO_VERSION, v, NULL) != 1) {
        set_ossl_err("set minimum TLS version");
        return -1;
    }
    return 0;
}

/* ── Client ───────────────────────────────────────────────────────────── */

void* lyric_tls_client_new(const char* ca_pem, int32_t min_version, int32_t insecure) {
    if (!tls_ready()) return NULL;
    ossl_ssl_ctx* ctx = O.SSL_CTX_new(O.TLS_client_method());
    if (!ctx) {
        set_ossl_err("create client TLS context");
        return NULL;
    }
    /* TLS 1.2 floor (docs/61 §3/§5.1); `min_version` 13 pins TLS 1.3. */
    if (set_min_version(ctx, min_version) != 0) {
        O.SSL_CTX_free(ctx);
        return NULL;
    }
    if (insecure) {
        O.SSL_CTX_set_verify(ctx, OSSL_SSL_VERIFY_NONE, NULL);
    } else {
        O.SSL_CTX_set_verify(ctx, OSSL_SSL_VERIFY_PEER, NULL);
        if (ca_pem && ca_pem[0] != '\0') {
            if (add_ca(ctx, ca_pem) != 0) {
                O.SSL_CTX_free(ctx);
                return NULL;
            }
        } else {
            /* system trust: default paths + SSL_CERT_FILE / SSL_CERT_DIR */
            if (O.SSL_CTX_set_default_verify_paths(ctx) != 1) {
                set_ossl_err("load system trust store");
                O.SSL_CTX_free(ctx);
                return NULL;
            }
        }
    }
    lyric_tls_ctx_t* w = (lyric_tls_ctx_t*)calloc(1, sizeof(lyric_tls_ctx_t));
    if (!w) {
        O.SSL_CTX_free(ctx);
        set_err("out of memory");
        return NULL;
    }
    w->ctx = ctx;
    w->insecure = insecure ? 1 : 0;
    return w;
}

int32_t lyric_tls_client_set_identity(void* client_ctx, const char* cert_pem, const char* key_pem) {
    if (!tls_ready() || !client_ctx) return -1;
    lyric_tls_ctx_t* w = (lyric_tls_ctx_t*)client_ctx;
    return use_identity(w->ctx, cert_pem ? cert_pem : "", key_pem ? key_pem : "") == 0 ? 0 : -1;
}

void* lyric_tls_client_connect(void* client_ctx, int32_t fd, const char* sni_host, const char* alpn_csv) {
    if (!tls_ready() || !client_ctx) return NULL;
    lyric_tls_ctx_t* w = (lyric_tls_ctx_t*)client_ctx;
    ossl_ssl* ssl = O.SSL_new(w->ctx);
    if (!ssl) {
        set_ossl_err("create client TLS connection");
        return NULL;
    }
    if (O.SSL_set_fd(ssl, fd) != 1) {
        set_ossl_err("bind socket to TLS connection");
        O.SSL_free(ssl);
        return NULL;
    }
    /* Hostname verification is hard-wired on for every non-insecure client
     * connection (docs/61 §7 item 3).  FAIL CLOSED: with verification enabled
     * and no host to verify against, refuse the connect rather than silently
     * downgrading to chain-only validation (the #6109 MITM-adjacent hole — the
     * native sibling of the dotnet #5950 fix).  Only the insecure override may
     * skip SSL_set1_host. */
    int has_host = sni_host && sni_host[0] != '\0';
    if (!w->insecure && !has_host) {
        set_err("hostname verification is enabled but no host was provided to "
                "verify against; refusing to connect (use the insecure override "
                "to disable verification)");
        O.SSL_free(ssl);
        return NULL;
    }
    if (has_host) {
        /* SNI is sent on every named connection. */
        O.SSL_ctrl(ssl, OSSL_SSL_CTRL_SET_TLSEXT_HOSTNAME,
                   OSSL_TLSEXT_NAMETYPE_host_name, (void*)sni_host);
        if (!w->insecure) {
            if (O.SSL_set1_host(ssl, sni_host) != 1) {
                set_ossl_err("set verification hostname");
                O.SSL_free(ssl);
                return NULL;
            }
        }
    }
    unsigned char* wire = NULL;
    unsigned int wire_len = 0;
    if (build_alpn_wire(alpn_csv, &wire, &wire_len) != 0) {
        set_err("malformed ALPN protocol list");
        O.SSL_free(ssl);
        return NULL;
    }
    if (wire) {
        O.SSL_set_alpn_protos(ssl, wire, wire_len);
        free(wire);
    }
    if (O.SSL_connect(ssl) != 1) {
        set_ossl_err("TLS handshake");
        O.SSL_free(ssl);
        return NULL;
    }
    if (!w->insecure) {
        long vr = O.SSL_get_verify_result(ssl);
        if (vr != OSSL_X509_V_OK) {
            set_err("certificate verification failed (code %ld)", vr);
            O.SSL_free(ssl);
            return NULL;
        }
    }
    return ssl;
}

/* ── Server ───────────────────────────────────────────────────────────── */

static int server_alpn_select(ossl_ssl* ssl, const unsigned char** out, unsigned char* outlen,
                              const unsigned char* in, unsigned int inlen, void* arg) {
    (void)ssl;
    lyric_tls_ctx_t* w = (lyric_tls_ctx_t*)arg;
    if (!w || !w->alpn_wire || w->alpn_len == 0) return OSSL_SSL_TLSEXT_ERR_NOACK;
    /* Server preference order wins: server list is the "preferred" arg. */
    if (O.SSL_select_next_proto((unsigned char**)out, outlen, w->alpn_wire, w->alpn_len, in, inlen) == 1) {
        return OSSL_SSL_TLSEXT_ERR_OK; /* OPENSSL_NPN_NEGOTIATED */
    }
    return OSSL_SSL_TLSEXT_ERR_NOACK; /* no overlap: proceed without ALPN */
}

void* lyric_tls_server_new(const char* cert_pem, const char* key_pem,
                           int32_t min_version, const char* client_ca_pem,
                           int32_t require_client_cert, const char* alpn_csv) {
    if (!tls_ready()) return NULL;
    if (!cert_pem || cert_pem[0] == '\0' || !key_pem || key_pem[0] == '\0') {
        set_err("server identity requires both a certificate and a private key");
        return NULL;
    }
    ossl_ssl_ctx* ctx = O.SSL_CTX_new(O.TLS_server_method());
    if (!ctx) {
        set_ossl_err("create server TLS context");
        return NULL;
    }
    if (set_min_version(ctx, min_version) != 0 ||
        use_identity(ctx, cert_pem, key_pem) != 0) {
        O.SSL_CTX_free(ctx);
        return NULL;
    }
    /* Mutual TLS: pin client trust to client_ca_pem and (optionally) require
     * a certificate.  Refusing to fall back to the system trust store when a
     * client cert is required but no CA is pinned is a Lyric-layer guard
     * (Std.TcpHost.validateServerConfig, #6042); the seam verifies only
     * against the anchors it is given. */
    if (client_ca_pem && client_ca_pem[0] != '\0') {
        if (add_ca(ctx, client_ca_pem) != 0) {
            O.SSL_CTX_free(ctx);
            return NULL;
        }
        int mode = OSSL_SSL_VERIFY_PEER;
        if (require_client_cert) mode |= OSSL_SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
        O.SSL_CTX_set_verify(ctx, mode, NULL);
    }
    lyric_tls_ctx_t* w = (lyric_tls_ctx_t*)calloc(1, sizeof(lyric_tls_ctx_t));
    if (!w) {
        O.SSL_CTX_free(ctx);
        set_err("out of memory");
        return NULL;
    }
    w->ctx = ctx;
    if (build_alpn_wire(alpn_csv, &w->alpn_wire, &w->alpn_len) != 0) {
        set_err("malformed ALPN protocol list");
        O.SSL_CTX_free(ctx);
        free(w);
        return NULL;
    }
    if (w->alpn_wire) {
        O.SSL_CTX_set_alpn_select_cb(ctx, server_alpn_select, w);
    }
    return w;
}

void* lyric_tls_server_accept(void* server_ctx, int32_t fd) {
    if (!tls_ready() || !server_ctx) return NULL;
    lyric_tls_ctx_t* w = (lyric_tls_ctx_t*)server_ctx;
    ossl_ssl* ssl = O.SSL_new(w->ctx);
    if (!ssl) {
        set_ossl_err("create server TLS connection");
        return NULL;
    }
    if (O.SSL_set_fd(ssl, fd) != 1) {
        set_ossl_err("bind socket to TLS connection");
        O.SSL_free(ssl);
        return NULL;
    }
    if (O.SSL_accept(ssl) != 1) {
        set_ossl_err("TLS handshake");
        O.SSL_free(ssl);
        return NULL;
    }
    return ssl;
}

/* ── Shared connection I/O ────────────────────────────────────────────── */

int64_t lyric_tls_read(void* conn, uint8_t* buf, int64_t n) {
    if (!conn || n <= 0) return 0;
    ossl_ssl* ssl = (ossl_ssl*)conn;
    int want = (n > 0x7fffffff) ? 0x7fffffff : (int)n;
    for (;;) {
        int r = O.SSL_read(ssl, buf, want);
        if (r > 0) return (int64_t)r;
        int err = O.SSL_get_error(ssl, r);
        if (err == OSSL_SSL_ERROR_ZERO_RETURN) return 0; /* clean close_notify */
        if (err == OSSL_SSL_ERROR_WANT_READ || err == OSSL_SSL_ERROR_WANT_WRITE) continue;
        set_ossl_err("TLS read");
        return -1;
    }
}

int64_t lyric_tls_write(void* conn, const uint8_t* buf, int64_t n) {
    if (!conn) return -1;
    if (n <= 0) return 0;
    ossl_ssl* ssl = (ossl_ssl*)conn;
    int64_t off = 0;
    while (off < n) {
        int64_t remaining = n - off;
        int chunk = (remaining > 0x7fffffff) ? 0x7fffffff : (int)remaining;
        int w = O.SSL_write(ssl, buf + off, chunk);
        if (w > 0) {
            off += w;
            continue;
        }
        int err = O.SSL_get_error(ssl, w);
        if (err == OSSL_SSL_ERROR_WANT_READ || err == OSSL_SSL_ERROR_WANT_WRITE) continue;
        set_ossl_err("TLS write");
        return -1;
    }
    return n;
}

int32_t lyric_tls_alpn(void* conn, char* out, int32_t out_cap) {
    if (!conn || !out || out_cap <= 0) return 0;
    ossl_ssl* ssl = (ossl_ssl*)conn;
    const unsigned char* data = NULL;
    unsigned int len = 0;
    O.SSL_get0_alpn_selected(ssl, &data, &len);
    if (!data || len == 0) {
        out[0] = '\0';
        return 0;
    }
    unsigned int copy = len;
    if (copy > (unsigned int)(out_cap - 1)) copy = (unsigned int)(out_cap - 1);
    memcpy(out, data, copy);
    out[copy] = '\0';
    return (int32_t)copy;
}

void lyric_tls_shutdown(void* conn) {
    if (!conn) return;
    O.SSL_shutdown((ossl_ssl*)conn);
}

void lyric_tls_free(void* conn) {
    if (!conn) return;
    O.SSL_free((ossl_ssl*)conn);
}

void lyric_tls_ctx_free(void* ctx) {
    if (!ctx) return;
    lyric_tls_ctx_t* w = (lyric_tls_ctx_t*)ctx;
    if (w->ctx) O.SSL_CTX_free(w->ctx);
    if (w->alpn_wire) free(w->alpn_wire);
    free(w);
}
