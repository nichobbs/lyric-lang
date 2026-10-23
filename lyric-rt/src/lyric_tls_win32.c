/* lyric_tls_win32.c — the Windows twin of lyric_tls.c's TLS half (docs/67
 * G9, #8434, D209): the lyric_tls_* seam over Schannel (SSPI), the TLS
 * implementation Windows ships, so a program needs no extra library and
 * trusts what the Windows certificate store trusts.
 *
 * Each entry point keeps lyric_tls.c's contract (lyric_rt.h).  How it is met:
 *
 *   - PEM certificates and PKCS#8 keys are decoded with CryptoAPI and CNG.
 *     A context's private key is imported into the Microsoft Software Key
 *     Storage Provider under a unique name, because Schannel opens keys in
 *     the LSA process and cannot use an in-memory one, and the key is
 *     deleted when the context is freed (and at exit for any still open).
 *   - Server certificates are checked by the runtime, never by Schannel's
 *     own defaults (SCH_CRED_MANUAL_CRED_VALIDATION): the chain is built
 *     with CertGetCertificateChain against the Windows roots, against only
 *     the caller's anchors (a chain engine with an exclusive root store), or
 *     against either, and checked with the SSL policy, which matches the
 *     host name.  Revocation is not checked, as in the OpenSSL seam.
 *   - Protocol versions are TLS 1.2 and 1.3, or 1.3 only; TLS 1.3 needs a
 *     Windows release whose Schannel offers it (Windows 11, Server 2022).
 *   - A server that asks for client certificates names its client CA store
 *     to Schannel (hRootStore) and the runtime checks the presented chain
 *     against those anchors once the handshake completes.
 */
#define SECURITY_WIN32
#define SCHANNEL_USE_BLACKLISTS

#include "lyric_rt.h"
#include "lyric_win32_internal.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <wincrypt.h>
#include <ncrypt.h>
#include <subauth.h>
#include <schannel.h>
#include <security.h>
#include <sspi.h>

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define set_err lyric_net_set_err

/* Records `what: <message for the SSPI or Win32 status>`. */
static void set_status_err(const char* what, long status) {
    char msg[200];
    lyric_win32_message((DWORD)status, msg, sizeof msg);
    set_err("%s: %s", what, msg);
}

int32_t lyric_tls_available(void) {
    return 1;
}

/* ── PEM ───────────────────────────────────────────────────────────── */

static int add_cert_to_store(const BYTE* der, DWORD len, HCERTSTORE store, PCCERT_CONTEXT* added) {
    return CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING, der, len, CERT_STORE_ADD_ALWAYS, added) ? 0
                                                                                                             : -1;
}

/* A memory store holding every certificate in `pem`, or NULL (last_error
 * set) when there is none or one does not parse.  With `first` non-NULL it
 * also returns the certificate of the first PEM block (the caller frees it):
 * a memory store does not enumerate in the order certificates were added, so
 * the leaf of a "leaf, then intermediates" PEM is taken from here. */
static HCERTSTORE read_cert_store(const char* pem, const char* what, PCCERT_CONTEXT* first) {
    if (first) *first = NULL;
    HCERTSTORE store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, NULL);
    if (!store) {
        set_status_err(what, (long)GetLastError());
        return NULL;
    }
    int failed = 0;
    const char* p = pem ? pem : "";
    const char* begin = "-----BEGIN CERTIFICATE-----";
    const char* end = "-----END CERTIFICATE-----";
    int count = 0;
    while (!failed && (p = strstr(p, begin)) != NULL) {
        const char* body = p + strlen(begin);
        const char* stop = strstr(body, end);
        DWORD len = 0;
        BYTE* der = NULL;
        if (!stop || !CryptStringToBinaryA(body, (DWORD)(stop - body), CRYPT_STRING_BASE64, NULL, &len, NULL, NULL) ||
            (der = (BYTE*)malloc(len ? len : 1)) == NULL ||
            !CryptStringToBinaryA(body, (DWORD)(stop - body), CRYPT_STRING_BASE64, der, &len, NULL, NULL) ||
            add_cert_to_store(der, len, store, (first && count == 0) ? first : NULL) != 0) {
            failed = 1;
        } else {
            count++;
            p = stop + strlen(end);
        }
        free(der);
    }
    if (failed || count == 0) {
        if (first && *first) {
            CertFreeCertificateContext(*first);
            *first = NULL;
        }
        CertCloseStore(store, 0);
        set_err("%s: no valid PEM certificate", what);
        return NULL;
    }
    return store;
}

/* The DER bytes of the first `-----BEGIN PRIVATE KEY-----` block (unencrypted
 * PKCS#8, the only form Std.Tls accepts), malloc'd, or NULL. */
static BYTE* read_pkcs8(const char* pem, DWORD* out_len) {
    const char* begin = "-----BEGIN PRIVATE KEY-----";
    const char* end = "-----END PRIVATE KEY-----";
    const char* p = pem ? strstr(pem, begin) : NULL;
    if (!p) return NULL;
    const char* body = p + strlen(begin);
    const char* stop = strstr(body, end);
    if (!stop) return NULL;
    DWORD len = 0;
    if (!CryptStringToBinaryA(body, (DWORD)(stop - body), CRYPT_STRING_BASE64, NULL, &len, NULL, NULL)) return NULL;
    BYTE* der = (BYTE*)malloc(len ? len : 1);
    if (!der) return NULL;
    if (!CryptStringToBinaryA(body, (DWORD)(stop - body), CRYPT_STRING_BASE64, der, &len, NULL, NULL)) {
        free(der);
        return NULL;
    }
    *out_len = len;
    return der;
}

/* ── Private keys ──────────────────────────────────────────────────── */

/* Keys this process has persisted for a context, deleted at exit if a
 * context was never freed. */
typedef struct KeyEntry {
    wchar_t name[64];
    struct KeyEntry* next;
} KeyEntry;

static SRWLOCK keys_lock = SRWLOCK_INIT;
static KeyEntry* keys_live = NULL;
static volatile LONG64 key_serial = 0;
static INIT_ONCE keys_atexit_once = INIT_ONCE_STATIC_INIT;

static void delete_key_named(const wchar_t* name) {
    NCRYPT_PROV_HANDLE prov = 0;
    if (NCryptOpenStorageProvider(&prov, MS_KEY_STORAGE_PROVIDER, 0) != ERROR_SUCCESS) return;
    NCRYPT_KEY_HANDLE key = 0;
    if (NCryptOpenKey(prov, &key, name, 0, NCRYPT_SILENT_FLAG) == ERROR_SUCCESS) {
        NCryptDeleteKey(key, NCRYPT_SILENT_FLAG); /* also frees the handle */
    }
    NCryptFreeObject(prov);
}

static void delete_live_keys(void) {
    AcquireSRWLockExclusive(&keys_lock);
    KeyEntry* e = keys_live;
    keys_live = NULL;
    ReleaseSRWLockExclusive(&keys_lock);
    while (e) {
        KeyEntry* next = e->next;
        delete_key_named(e->name);
        free(e);
        e = next;
    }
}

static BOOL CALLBACK register_keys_atexit(PINIT_ONCE once, PVOID param, PVOID* ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    atexit(delete_live_keys);
    return TRUE;
}

static void forget_key(const wchar_t* name) {
    AcquireSRWLockExclusive(&keys_lock);
    KeyEntry** at = &keys_live;
    while (*at && wcscmp((*at)->name, name) != 0) at = &(*at)->next;
    KeyEntry* found = *at;
    if (found) *at = found->next;
    ReleaseSRWLockExclusive(&keys_lock);
    free(found);
}

/* Imports the PKCS#8 key in `key_pem`.  With `name` non-NULL the key is
 * persisted under that name (so Schannel can open it); otherwise it is an
 * ephemeral key, for validation.  0 and *out on success. */
static int import_key(const char* key_pem, const wchar_t* name, NCRYPT_KEY_HANDLE* out) {
    DWORD len = 0;
    BYTE* der = read_pkcs8(key_pem, &len);
    if (!der) {
        set_err("parse private key (only unencrypted PKCS#8 is supported)");
        return -1;
    }
    NCRYPT_PROV_HANDLE prov = 0;
    SECURITY_STATUS st = NCryptOpenStorageProvider(&prov, MS_KEY_STORAGE_PROVIDER, 0);
    if (st != ERROR_SUCCESS) {
        free(der);
        set_status_err("open the key storage provider", st);
        return -1;
    }
    NCryptBuffer nb;
    NCryptBufferDesc desc;
    NCryptBufferDesc* params = NULL;
    if (name) {
        nb.cbBuffer = (ULONG)((wcslen(name) + 1) * sizeof(wchar_t));
        nb.BufferType = NCRYPTBUFFER_PKCS_KEY_NAME;
        nb.pvBuffer = (PVOID)name;
        desc.ulVersion = NCRYPTBUFFER_VERSION;
        desc.cBuffers = 1;
        desc.pBuffers = &nb;
        params = &desc;
    }
    NCRYPT_KEY_HANDLE key = 0;
    st = NCryptImportKey(prov, 0, NCRYPT_PKCS8_PRIVATE_KEY_BLOB, params, &key, der, len,
                         NCRYPT_SILENT_FLAG | (name ? NCRYPT_OVERWRITE_KEY_FLAG : 0));
    SecureZeroMemory(der, len);
    free(der);
    NCryptFreeObject(prov);
    if (st != ERROR_SUCCESS) {
        set_status_err("parse private key (only unencrypted PKCS#8 is supported)", st);
        return -1;
    }
    *out = key;
    return 0;
}

/* 1 when the public half of `key` is the certificate's public key. */
static int key_matches_cert(NCRYPT_KEY_HANDLE key, PCCERT_CONTEXT cert) {
    DWORD size = 0;
    if (!CryptExportPublicKeyInfo((HCRYPTPROV_OR_NCRYPT_KEY_HANDLE)key, CERT_NCRYPT_KEY_SPEC, X509_ASN_ENCODING, NULL, &size)) return 0;
    CERT_PUBLIC_KEY_INFO* info = (CERT_PUBLIC_KEY_INFO*)malloc(size);
    if (!info) return 0;
    int same = CryptExportPublicKeyInfo((HCRYPTPROV_OR_NCRYPT_KEY_HANDLE)key, CERT_NCRYPT_KEY_SPEC, X509_ASN_ENCODING, info, &size) &&
               CertComparePublicKeyInfo(X509_ASN_ENCODING, &cert->pCertInfo->SubjectPublicKeyInfo, info);
    free(info);
    return same;
}

/* ── Identities ────────────────────────────────────────────────────── */

typedef struct {
    HCERTSTORE chain;     /* leaf first, then any intermediates */
    PCCERT_CONTEXT leaf;  /* bound to the persisted key */
    wchar_t key_name[64]; /* empty when there is no persisted key */
} Identity;

static void identity_free(Identity* id) {
    if (id->leaf) CertFreeCertificateContext(id->leaf);
    if (id->chain) CertCloseStore(id->chain, 0);
    if (id->key_name[0]) {
        delete_key_named(id->key_name);
        forget_key(id->key_name);
    }
    memset(id, 0, sizeof *id);
}

/* Loads `cert_pem` (leaf, then intermediates) and `key_pem`, checks they
 * match, and persists the key for Schannel.  0 on success. */
static int identity_load(Identity* id, const char* cert_pem, const char* key_pem) {
    memset(id, 0, sizeof *id);
    id->chain = read_cert_store(cert_pem, "parse certificate", &id->leaf);
    if (!id->chain) return -1;
    if (!id->leaf) {
        set_err("parse certificate: no certificate");
        identity_free(id);
        return -1;
    }
    InitOnceExecuteOnce(&keys_atexit_once, register_keys_atexit, NULL, NULL);
    uint8_t r[8];
    lyric_secure_random(r, sizeof r);
    _snwprintf(id->key_name, sizeof id->key_name / sizeof id->key_name[0],
               L"lyric-tls-%lu-%lld-%02x%02x%02x%02x%02x%02x%02x%02x", (unsigned long)GetCurrentProcessId(),
               (long long)InterlockedIncrement64(&key_serial), r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
    id->key_name[sizeof id->key_name / sizeof id->key_name[0] - 1] = L'\0';
    NCRYPT_KEY_HANDLE key = 0;
    if (import_key(key_pem, id->key_name, &key) != 0) {
        id->key_name[0] = L'\0';
        identity_free(id);
        return -1;
    }
    KeyEntry* e = (KeyEntry*)calloc(1, sizeof(KeyEntry));
    if (!e) {
        /* Unregistered, the key would outlive the process: delete it now. */
        NCryptDeleteKey(key, NCRYPT_SILENT_FLAG); /* also frees the handle */
        id->key_name[0] = L'\0';
        identity_free(id);
        set_err("out of memory");
        return -1;
    }
    wcscpy(e->name, id->key_name);
    AcquireSRWLockExclusive(&keys_lock);
    e->next = keys_live;
    keys_live = e;
    ReleaseSRWLockExclusive(&keys_lock);
    int matches = key_matches_cert(key, id->leaf);
    NCryptFreeObject(key);
    if (!matches) {
        set_err("certificate/key mismatch");
        identity_free(id);
        return -1;
    }
    CRYPT_KEY_PROV_INFO prov;
    memset(&prov, 0, sizeof prov);
    prov.pwszContainerName = id->key_name;
    prov.pwszProvName = (LPWSTR)MS_KEY_STORAGE_PROVIDER;
    prov.dwProvType = 0; /* a CNG key */
    if (!CertSetCertificateContextProperty(id->leaf, CERT_KEY_PROV_INFO_PROP_ID, 0, &prov)) {
        set_status_err("use private key", (long)GetLastError());
        identity_free(id);
        return -1;
    }
    return 0;
}

/* ── Validation (Std.TlsHost.fromPem) ──────────────────────────────── */

int32_t lyric_tls_validate_cert_pem(const char* cert_pem) {
    HCERTSTORE s = read_cert_store(cert_pem, "parse certificate", NULL);
    if (!s) return 0;
    CertCloseStore(s, 0);
    return 1;
}

int32_t lyric_tls_validate_key_pem(const char* key_pem) {
    NCRYPT_KEY_HANDLE key = 0;
    if (import_key(key_pem, NULL, &key) != 0) return 0;
    NCryptFreeObject(key);
    return 1;
}

int32_t lyric_tls_validate_identity_pem(const char* cert_pem, const char* key_pem) {
    PCCERT_CONTEXT leaf = NULL;
    HCERTSTORE s = read_cert_store(cert_pem, "parse certificate", &leaf);
    if (!s) return 0;
    NCRYPT_KEY_HANDLE key = 0;
    int ok = leaf && import_key(key_pem, NULL, &key) == 0;
    if (ok && !key_matches_cert(key, leaf)) {
        set_err("certificate/key mismatch");
        ok = 0;
    }
    if (key) NCryptFreeObject(key);
    if (leaf) CertFreeCertificateContext(leaf);
    CertCloseStore(s, 0);
    return ok ? 1 : 0;
}

/* ── Contexts ──────────────────────────────────────────────────────── */

enum { TRUST_SYSTEM = 0, TRUST_EXCLUSIVE = 1, TRUST_ADDITIVE = 2 };

typedef struct {
    int is_server;
    int insecure;
    int tls13_only;
    int trust;
    HCERTSTORE anchors;      /* caller-supplied CA certificates, or NULL */
    HCERTCHAINENGINE engine; /* trusts only `anchors`, or NULL */
    Identity identity;       /* server identity, or client certificate */
    int have_identity;
    int verify_client;
    int require_client_cert;
    uint8_t* alpn_wire;
    unsigned int alpn_len;
    SRWLOCK lock;
    CredHandle cred;
    int have_cred;
} TlsCtx;

/* ALPN "h2,http/1.1" in wire form (length-prefixed names). 0, or -1 for a
 * malformed list. */
static int build_alpn_wire(const char* csv, uint8_t** out, unsigned int* out_len) {
    *out = NULL;
    *out_len = 0;
    if (!csv || csv[0] == '\0') return 0;
    size_t total = strlen(csv) + 8;
    uint8_t* buf = (uint8_t*)malloc(total);
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
        buf[w++] = (uint8_t)seg;
        memcpy(buf + w, p, seg);
        w += (unsigned int)seg;
        if (!comma) break;
        p = comma + 1;
    }
    *out = buf;
    *out_len = w;
    return 0;
}

/* A SEC_APPLICATION_PROTOCOLS buffer for an ALPN wire list (malloc'd), and
 * its size. */
static uint8_t* alpn_sspi_buffer(const uint8_t* wire, unsigned int wire_len, unsigned long* out_size) {
    size_t list_hdr = offsetof(SEC_APPLICATION_PROTOCOL_LIST, ProtocolList);
    size_t size = offsetof(SEC_APPLICATION_PROTOCOLS, ProtocolLists) + list_hdr + wire_len;
    uint8_t* buf = (uint8_t*)calloc(1, size);
    if (!buf) return NULL;
    SEC_APPLICATION_PROTOCOLS* protos = (SEC_APPLICATION_PROTOCOLS*)buf;
    protos->ProtocolListsSize = (unsigned long)(list_hdr + wire_len);
    SEC_APPLICATION_PROTOCOL_LIST* list = &protos->ProtocolLists[0];
    list->ProtoNegoExt = SecApplicationProtocolNegotiationExt_ALPN;
    list->ProtocolListSize = (unsigned short)wire_len;
    memcpy(list->ProtocolList, wire, wire_len);
    *out_size = (unsigned long)size;
    return buf;
}

static TlsCtx* ctx_new(int is_server, int32_t min_version) {
    TlsCtx* c = (TlsCtx*)calloc(1, sizeof(TlsCtx));
    if (!c) {
        set_err("out of memory");
        return NULL;
    }
    c->is_server = is_server;
    c->tls13_only = min_version >= 13;
    InitializeSRWLock(&c->lock);
    return c;
}

void lyric_tls_ctx_free(void* raw) {
    TlsCtx* c = (TlsCtx*)raw;
    if (!c) return;
    if (c->have_cred) FreeCredentialsHandle(&c->cred);
    if (c->engine) CertFreeCertificateChainEngine(c->engine);
    if (c->anchors) CertCloseStore(c->anchors, 0);
    if (c->have_identity) identity_free(&c->identity);
    free(c->alpn_wire);
    free(c);
}

/* A chain engine whose only trust anchors are the certificates in `roots`. */
static HCERTCHAINENGINE exclusive_engine(HCERTSTORE roots) {
    CERT_CHAIN_ENGINE_CONFIG cfg;
    memset(&cfg, 0, sizeof cfg);
    /* The Windows 7 layout (up to hExclusiveTrustedPeople), which every
     * release since accepts; dwExclusiveFlags is not needed. */
    cfg.cbSize = (DWORD)offsetof(CERT_CHAIN_ENGINE_CONFIG, dwExclusiveFlags);
    cfg.hExclusiveRoot = roots;
    HCERTCHAINENGINE engine = NULL;
    if (!CertCreateCertificateChainEngine(&cfg, &engine)) {
        set_status_err("load CA certificate", (long)GetLastError());
        return NULL;
    }
    return engine;
}

static int set_anchors(TlsCtx* c, const char* ca_pem) {
    c->anchors = read_cert_store(ca_pem, "parse CA certificate", NULL);
    if (!c->anchors) return -1;
    c->engine = exclusive_engine(c->anchors);
    return c->engine ? 0 : -1;
}

/* Acquires the context's Schannel credentials (once; the client's are
 * acquired on first connect so a later client certificate is included). */
static int ensure_cred(TlsCtx* c) {
    AcquireSRWLockExclusive(&c->lock);
    if (c->have_cred) {
        ReleaseSRWLockExclusive(&c->lock);
        return 0;
    }
    PCCERT_CONTEXT certs[1];
    DWORD n_certs = 0;
    if (c->have_identity) certs[n_certs++] = c->identity.leaf;
    DWORD allowed = c->is_server ? (SP_PROT_TLS1_3_SERVER | (c->tls13_only ? 0 : SP_PROT_TLS1_2_SERVER))
                                 : (SP_PROT_TLS1_3_CLIENT | (c->tls13_only ? 0 : SP_PROT_TLS1_2_CLIENT));
    DWORD flags = SCH_USE_STRONG_CRYPTO;
    if (c->is_server) {
        flags |= SCH_CRED_NO_SYSTEM_MAPPER; /* no mapping of client certificates to Windows accounts */
    } else {
        flags |= SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS;
    }

    TLS_PARAMETERS tp;
    memset(&tp, 0, sizeof tp);
    tp.grbitDisabledProtocols = ~allowed;
    SCH_CREDENTIALS sc;
    memset(&sc, 0, sizeof sc);
    sc.dwVersion = SCH_CREDENTIALS_VERSION;
    sc.cCreds = n_certs;
    sc.paCred = n_certs ? certs : NULL;
    sc.hRootStore = c->is_server && c->verify_client ? c->anchors : NULL;
    sc.dwFlags = flags;
    sc.cTlsParameters = 1;
    sc.pTlsParameters = &tp;
    TimeStamp expiry;
    SECURITY_STATUS st = AcquireCredentialsHandleW(NULL, (LPWSTR)UNISP_NAME_W,
                                                   c->is_server ? SECPKG_CRED_INBOUND : SECPKG_CRED_OUTBOUND, NULL,
                                                   &sc, NULL, NULL, &c->cred, &expiry);
    if (st != SEC_E_OK && !c->tls13_only) {
        /* Releases before Windows 10 1809 know only SCHANNEL_CRED, which
         * cannot offer TLS 1.3. */
        SCHANNEL_CRED legacy;
        memset(&legacy, 0, sizeof legacy);
        legacy.dwVersion = SCHANNEL_CRED_VERSION;
        legacy.cCreds = n_certs;
        legacy.paCred = n_certs ? certs : NULL;
        legacy.hRootStore = sc.hRootStore;
        legacy.grbitEnabledProtocols = c->is_server ? SP_PROT_TLS1_2_SERVER : SP_PROT_TLS1_2_CLIENT;
        legacy.dwFlags = flags;
        st = AcquireCredentialsHandleW(NULL, (LPWSTR)UNISP_NAME_W,
                                       c->is_server ? SECPKG_CRED_INBOUND : SECPKG_CRED_OUTBOUND, NULL, &legacy, NULL,
                                       NULL, &c->cred, &expiry);
    }
    if (st != SEC_E_OK) {
        ReleaseSRWLockExclusive(&c->lock);
        set_status_err(c->tls13_only ? "TLS credentials (TLS 1.3 needs Windows 11 or Server 2022)" : "TLS credentials",
                       st);
        return -1;
    }
    c->have_cred = 1;
    ReleaseSRWLockExclusive(&c->lock);
    return 0;
}

static void* client_new(const char* ca_pem, int32_t min_version, int32_t insecure, int additive) {
    TlsCtx* c = ctx_new(0, min_version);
    if (!c) return NULL;
    c->insecure = insecure ? 1 : 0;
    int have_ca = ca_pem && ca_pem[0] != '\0';
    if (!c->insecure) {
        if (additive && !have_ca) {
            set_err("additive client context requires a non-empty ca_pem");
            lyric_tls_ctx_free(c);
            return NULL;
        }
        if (have_ca) {
            if (set_anchors(c, ca_pem) != 0) {
                lyric_tls_ctx_free(c);
                return NULL;
            }
            c->trust = additive ? TRUST_ADDITIVE : TRUST_EXCLUSIVE;
        }
    }
    return c;
}

void* lyric_tls_client_new(const char* ca_pem, int32_t min_version, int32_t insecure) {
    return client_new(ca_pem, min_version, insecure, 0);
}

void* lyric_tls_client_new_additive(const char* ca_pem, int32_t min_version, int32_t insecure) {
    return client_new(ca_pem, min_version, insecure, 1);
}

int32_t lyric_tls_client_set_identity(void* raw, const char* cert_pem, const char* key_pem) {
    TlsCtx* c = (TlsCtx*)raw;
    if (!c || c->is_server) return -1;
    // Connections made on this context hold its credential handle, so the
    // identity is fixed once the first connection has acquired it.
    AcquireSRWLockShared(&c->lock);
    int in_use = c->have_cred;
    ReleaseSRWLockShared(&c->lock);
    if (in_use) {
        set_err("a client identity must be set before the context's first connection");
        return -1;
    }
    Identity id;
    if (identity_load(&id, cert_pem ? cert_pem : "", key_pem ? key_pem : "") != 0) return -1;
    AcquireSRWLockExclusive(&c->lock);
    if (c->have_cred) {
        ReleaseSRWLockExclusive(&c->lock);
        identity_free(&id);
        set_err("a client identity must be set before the context's first connection");
        return -1;
    }
    if (c->have_identity) identity_free(&c->identity);
    c->identity = id;
    c->have_identity = 1;
    ReleaseSRWLockExclusive(&c->lock);
    return 0;
}

void* lyric_tls_server_new(const char* cert_pem, const char* key_pem, int32_t min_version, const char* client_ca_pem,
                           int32_t require_client_cert, const char* alpn_csv) {
    if (!cert_pem || cert_pem[0] == '\0' || !key_pem || key_pem[0] == '\0') {
        set_err("server identity requires both a certificate and a private key");
        return NULL;
    }
    TlsCtx* c = ctx_new(1, min_version);
    if (!c) return NULL;
    if (identity_load(&c->identity, cert_pem, key_pem) != 0) {
        lyric_tls_ctx_free(c);
        return NULL;
    }
    c->have_identity = 1;
    if (client_ca_pem && client_ca_pem[0] != '\0') {
        if (set_anchors(c, client_ca_pem) != 0) {
            lyric_tls_ctx_free(c);
            return NULL;
        }
        c->verify_client = 1;
        c->require_client_cert = require_client_cert ? 1 : 0;
    }
    if (build_alpn_wire(alpn_csv, &c->alpn_wire, &c->alpn_len) != 0) {
        set_err("malformed ALPN protocol list");
        lyric_tls_ctx_free(c);
        return NULL;
    }
    if (ensure_cred(c) != 0) {
        lyric_tls_ctx_free(c);
        return NULL;
    }
    return c;
}

/* ── IP-literal hosts ──────────────────────────────────────────────── */

/* The address bytes of `host` (4 or 16) when it is an IPv4 or IPv6
 * literal, optionally in brackets; 0 otherwise. */
static int ip_literal(const char* host, uint8_t out[16]) {
    char buf[64];
    size_t n = strlen(host);
    if (n >= 2 && host[0] == '[' && host[n - 1] == ']') {
        host++;
        n -= 2;
    }
    if (n == 0 || n >= sizeof buf) return 0;
    memcpy(buf, host, n);
    buf[n] = '\0';
    if (inet_pton(AF_INET, buf, out) == 1) return 4;
    if (inet_pton(AF_INET6, buf, out) == 1) return 16;
    return 0;
}

/* 1 when the certificate lists `ip` (`len` bytes) among its iPAddress
 * subject alternative names. */
static int cert_has_ip(PCCERT_CONTEXT cert, const uint8_t* ip, int len) {
    PCERT_EXTENSION ext = CertFindExtension(szOID_SUBJECT_ALT_NAME2, cert->pCertInfo->cExtension,
                                            cert->pCertInfo->rgExtension);
    if (!ext) return 0;
    CERT_ALT_NAME_INFO* names = NULL;
    DWORD size = 0;
    if (!CryptDecodeObjectEx(X509_ASN_ENCODING, X509_ALTERNATE_NAME, ext->Value.pbData, ext->Value.cbData,
                             CRYPT_DECODE_ALLOC_FLAG, NULL, &names, &size)) {
        return 0;
    }
    int found = 0;
    for (DWORD i = 0; i < names->cAltEntry && !found; i++) {
        const CERT_ALT_NAME_ENTRY* e = &names->rgAltEntry[i];
        found = e->dwAltNameChoice == CERT_ALT_NAME_IP_ADDRESS && e->IPAddress.cbData == (DWORD)len &&
                memcmp(e->IPAddress.pbData, ip, (size_t)len) == 0;
    }
    LocalFree(names);
    return found;
}

/* ── Certificate checks ────────────────────────────────────────────── */

/* 0 when `cert` (with the intermediates in its store) chains to a trusted
 * root of `engine` (NULL: the Windows roots) and passes the SSL policy for a
 * server (`server_auth`, matching `server_name` unless it is NULL) or a
 * client certificate; otherwise the error. */
static DWORD check_chain(HCERTCHAINENGINE engine, PCCERT_CONTEXT cert, int server_auth, const wchar_t* server_name) {
    CERT_CHAIN_PARA para;
    memset(&para, 0, sizeof para);
    para.cbSize = sizeof para;
    LPSTR usage = server_auth ? (LPSTR)szOID_PKIX_KP_SERVER_AUTH : (LPSTR)szOID_PKIX_KP_CLIENT_AUTH;
    para.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
    para.RequestedUsage.Usage.cUsageIdentifier = 1;
    para.RequestedUsage.Usage.rgpszUsageIdentifier = &usage;
    PCCERT_CHAIN_CONTEXT chain = NULL;
    if (!CertGetCertificateChain(engine, cert, NULL, cert->hCertStore, &para, 0, NULL, &chain)) {
        return GetLastError();
    }
    /* The SSL policy reports these too; checking the chain's own status as
     * well means no policy implementation can let an untrusted root, an
     * expired certificate or a wrong usage through. */
    DWORD trust = chain->TrustStatus.dwErrorStatus;
    if (trust != CERT_TRUST_NO_ERROR) {
        DWORD code = (trust & CERT_TRUST_IS_UNTRUSTED_ROOT)      ? (DWORD)CERT_E_UNTRUSTEDROOT
                     : (trust & CERT_TRUST_IS_NOT_TIME_VALID)     ? (DWORD)CERT_E_EXPIRED
                     : (trust & CERT_TRUST_IS_NOT_VALID_FOR_USAGE) ? (DWORD)CERT_E_WRONG_USAGE
                     : (trust & CERT_TRUST_IS_PARTIAL_CHAIN)      ? (DWORD)CERT_E_CHAINING
                     : (trust & CERT_TRUST_IS_REVOKED)            ? (DWORD)CRYPT_E_REVOKED
                                                                  : (DWORD)TRUST_E_CERT_SIGNATURE;
        CertFreeCertificateChain(chain);
        return code;
    }
    HTTPSPolicyCallbackData https;
    memset(&https, 0, sizeof https);
    https.cbStruct = sizeof https;
    https.dwAuthType = server_auth ? AUTHTYPE_SERVER : AUTHTYPE_CLIENT;
    https.pwszServerName = (WCHAR*)server_name;
    CERT_CHAIN_POLICY_PARA policy;
    memset(&policy, 0, sizeof policy);
    policy.cbSize = sizeof policy;
    policy.pvExtraPolicyPara = &https;
    CERT_CHAIN_POLICY_STATUS status;
    memset(&status, 0, sizeof status);
    status.cbSize = sizeof status;
    DWORD result;
    if (!CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain, &policy, &status)) {
        result = GetLastError();
    } else {
        result = status.dwError;
    }
    CertFreeCertificateChain(chain);
    return result;
}

/* Applies the context's trust rule to `cert`. */
static DWORD check_peer(const TlsCtx* c, PCCERT_CONTEXT cert, const wchar_t* server_name) {
    switch (c->trust) {
    case TRUST_EXCLUSIVE:
        return check_chain(c->engine, cert, 1, server_name);
    case TRUST_ADDITIVE: {
        DWORD system = check_chain(NULL, cert, 1, server_name);
        return system == 0 ? 0 : check_chain(c->engine, cert, 1, server_name);
    }
    default:
        return check_chain(NULL, cert, 1, server_name);
    }
}

/* ── Connections ───────────────────────────────────────────────────── */

typedef struct {
    TlsCtx* ctx;
    SOCKET s;
    CtxtHandle h;
    int have_h;
    SecPkgContext_StreamSizes sizes;
    uint8_t* in; /* received bytes not yet consumed by Schannel */
    size_t in_len;
    size_t in_cap;
    uint8_t* plain; /* decrypted bytes not yet returned */
    size_t plain_off;
    size_t plain_len;
    int eof;
    int renegotiating; /* a post-handshake message is being processed */
    char alpn[256];
} TlsConn;

static int in_reserve(TlsConn* t, size_t extra) {
    if (t->in_len + extra <= t->in_cap) return 0;
    size_t cap = t->in_cap ? t->in_cap : 16384;
    while (cap < t->in_len + extra) cap *= 2;
    uint8_t* p = (uint8_t*)realloc(t->in, cap);
    if (!p) return -1;
    t->in = p;
    t->in_cap = cap;
    return 0;
}

/* Receives more bytes into `in`.  1 on data, 0 on end of stream, -1 on an
 * error (last_error set, with `what` as context). */
static int recv_more(TlsConn* t, const char* what) {
    if (in_reserve(t, 16384) != 0) {
        set_err("out of memory");
        return -1;
    }
    for (;;) {
        int n = recv(t->s, (char*)t->in + t->in_len, (int)(t->in_cap - t->in_len), 0);
        if (n > 0) {
            t->in_len += (size_t)n;
            return 1;
        }
        if (n == 0) return 0;
        int e = WSAGetLastError();
        if (e == WSAEINTR) continue;
        if (lyric_win32_sock_timed_out(e)) {
            set_err("%s: timed out", what);
        } else {
            set_status_err(what, e);
        }
        return -1;
    }
}

static int send_all(SOCKET s, const uint8_t* p, size_t n, const char* what) {
    while (n > 0) {
        int chunk = n > INT32_MAX ? INT32_MAX : (int)n;
        int w = send(s, (const char*)p, chunk, 0);
        if (w <= 0) {
            int e = WSAGetLastError();
            if (w < 0 && e == WSAEINTR) continue;
            if (lyric_win32_sock_timed_out(e)) {
                set_err("%s: timed out", what);
            } else {
                set_status_err(what, e);
            }
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

/* Sends and frees any output tokens Schannel produced. */
static int flush_tokens(TlsConn* t, SecBuffer* out, unsigned long n, const char* what) {
    int rc = 0;
    for (unsigned long i = 0; i < n; i++) {
        if (out[i].pvBuffer && out[i].cbBuffer > 0 && rc == 0) {
            rc = send_all(t->s, (const uint8_t*)out[i].pvBuffer, out[i].cbBuffer, what);
        }
        if (out[i].pvBuffer) {
            FreeContextBuffer(out[i].pvBuffer);
            out[i].pvBuffer = NULL;
        }
    }
    return rc;
}

/* Keeps the unconsumed tail of `in` that Schannel reported as EXTRA. */
static void keep_extra(TlsConn* t, const SecBuffer* in_bufs, unsigned long n) {
    for (unsigned long i = 0; i < n; i++) {
        if (in_bufs[i].BufferType == SECBUFFER_EXTRA && in_bufs[i].cbBuffer > 0) {
            size_t extra = in_bufs[i].cbBuffer;
            memmove(t->in, t->in + (t->in_len - extra), extra);
            t->in_len = extra;
            return;
        }
    }
    t->in_len = 0;
}

static void conn_free(TlsConn* t) {
    if (t->have_h) DeleteSecurityContext(&t->h);
    free(t->in);
    free(t->plain);
    free(t);
}

static const ULONG CLIENT_REQ = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY |
                                ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM | ISC_REQ_EXTENDED_ERROR |
                                ISC_REQ_MANUAL_CRED_VALIDATION | ISC_REQ_USE_SUPPLIED_CREDS;
static const ULONG SERVER_REQ = ASC_REQ_SEQUENCE_DETECT | ASC_REQ_REPLAY_DETECT | ASC_REQ_CONFIDENTIALITY |
                                ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_STREAM | ASC_REQ_EXTENDED_ERROR;

/* One InitializeSecurityContextW / AcceptSecurityContext step over the bytes
 * in `in` (none on a client's first step), plus `alpn` when non-NULL.
 * Output tokens are sent.  Returns the SSPI status; on success the consumed
 * input is dropped and any EXTRA bytes are kept. */
static SECURITY_STATUS step(TlsConn* t, const wchar_t* target, uint8_t* alpn, unsigned long alpn_size,
                            const char* what, int* send_failed) {
    TlsCtx* c = t->ctx;
    SecBuffer in_bufs[3];
    unsigned long n_in = 0;
    int with_input = c->is_server || t->have_h;
    if (with_input) {
        in_bufs[n_in].BufferType = SECBUFFER_TOKEN;
        in_bufs[n_in].pvBuffer = t->in;
        in_bufs[n_in].cbBuffer = (unsigned long)t->in_len;
        n_in++;
        in_bufs[n_in].BufferType = SECBUFFER_EMPTY;
        in_bufs[n_in].pvBuffer = NULL;
        in_bufs[n_in].cbBuffer = 0;
        n_in++;
    }
    if (alpn) {
        in_bufs[n_in].BufferType = SECBUFFER_APPLICATION_PROTOCOLS;
        in_bufs[n_in].pvBuffer = alpn;
        in_bufs[n_in].cbBuffer = alpn_size;
        n_in++;
    }
    SecBufferDesc in_desc = {SECBUFFER_VERSION, n_in, in_bufs};
    SecBuffer out_bufs[2];
    out_bufs[0].BufferType = SECBUFFER_TOKEN;
    out_bufs[0].pvBuffer = NULL;
    out_bufs[0].cbBuffer = 0;
    out_bufs[1].BufferType = SECBUFFER_ALERT;
    out_bufs[1].pvBuffer = NULL;
    out_bufs[1].cbBuffer = 0;
    SecBufferDesc out_desc = {SECBUFFER_VERSION, 2, out_bufs};
    ULONG attrs = 0;
    SECURITY_STATUS st;
    if (c->is_server) {
        ULONG req = SERVER_REQ | (c->verify_client ? ASC_REQ_MUTUAL_AUTH : 0);
        st = AcceptSecurityContext(&c->cred, t->have_h ? &t->h : NULL, &in_desc, req, 0, &t->h, &out_desc, &attrs,
                                   NULL);
    } else {
        st = InitializeSecurityContextW(&c->cred, t->have_h ? &t->h : NULL, (SEC_WCHAR*)target, CLIENT_REQ, 0, 0,
                                        n_in ? &in_desc : NULL, 0, &t->h, &out_desc, &attrs, NULL);
    }
    if (!t->have_h && (st == SEC_E_OK || st == SEC_I_CONTINUE_NEEDED || st == SEC_I_INCOMPLETE_CREDENTIALS)) {
        t->have_h = 1;
    }
    /* A failing step may still carry an alert for the peer. */
    *send_failed = flush_tokens(t, out_bufs, 2, what) != 0;
    if (st == SEC_E_OK || st == SEC_I_CONTINUE_NEEDED) {
        if (with_input) keep_extra(t, in_bufs, 2);
    }
    return st;
}

/* Runs the handshake to completion: InitializeSecurityContextW for a
 * client, with `target` as the SNI and verification name, or
 * AcceptSecurityContext for a server.  `alpn` (a SEC_APPLICATION_PROTOCOLS
 * buffer) goes with the first step.  0 on success. */
static int handshake(TlsConn* t, const wchar_t* target, uint8_t* alpn, unsigned long alpn_size) {
    const char* what = "TLS handshake";
    int first = 1;
    int incomplete = 0;
    int need_input = t->ctx->is_server; /* a server starts from the ClientHello */
    for (;;) {
        if (need_input) {
            int r = recv_more(t, what);
            if (r == 0) {
                set_err("%s: the peer closed the connection", what);
                return -1;
            }
            if (r < 0) return -1;
        }
        int send_failed = 0;
        SECURITY_STATUS st = step(t, target, first ? alpn : NULL, alpn_size, what, &send_failed);
        if (FAILED(st) && st != SEC_E_INCOMPLETE_MESSAGE) {
            set_status_err(what, st);
            return -1;
        }
        if (send_failed) return -1; /* last_error set by the send */
        if (st == SEC_E_INCOMPLETE_MESSAGE) {
            need_input = 1;
            continue;
        }
        first = 0;
        if (st == SEC_E_OK) return 0;
        if (st == SEC_I_INCOMPLETE_CREDENTIALS) {
            /* The server asked for a client certificate and none was
             * supplied: go on without one (the input is not consumed).
             * Schannel asks once; a repeat means it cannot go on. */
            if (++incomplete > 2) {
                set_err("%s: the server asked for a client certificate this context cannot supply", what);
                return -1;
            }
            need_input = 0;
            continue;
        }
        need_input = t->in_len == 0;
    }
}

/* Queries the stream sizes and the negotiated ALPN after a handshake. */
static int finish_handshake(TlsConn* t) {
    SECURITY_STATUS st = QueryContextAttributesW(&t->h, SECPKG_ATTR_STREAM_SIZES, &t->sizes);
    if (st != SEC_E_OK) {
        set_status_err("TLS handshake", st);
        return -1;
    }
    SecPkgContext_ApplicationProtocol ap;
    memset(&ap, 0, sizeof ap);
    if (QueryContextAttributesW(&t->h, SECPKG_ATTR_APPLICATION_PROTOCOL, &ap) == SEC_E_OK &&
        ap.ProtoNegoStatus == SecApplicationProtocolNegotiationStatus_Success && ap.ProtocolIdSize > 0) {
        size_t n = ap.ProtocolIdSize < sizeof t->alpn - 1 ? ap.ProtocolIdSize : sizeof t->alpn - 1;
        memcpy(t->alpn, ap.ProtocolId, n);
        t->alpn[n] = '\0';
    }
    return 0;
}

static TlsConn* conn_new(TlsCtx* c, int32_t fd) {
    TlsConn* t = (TlsConn*)calloc(1, sizeof(TlsConn));
    if (!t) {
        set_err("out of memory");
        return NULL;
    }
    t->ctx = c;
    t->s = (SOCKET)(intptr_t)fd;
    return t;
}

void* lyric_tls_client_connect(void* raw, int32_t fd, const char* sni_host, const char* alpn_csv) {
    TlsCtx* c = (TlsCtx*)raw;
    if (!c || c->is_server) return NULL;
    int has_host = sni_host && sni_host[0] != '\0';
    if (!c->insecure && !has_host) {
        set_err("hostname verification is enabled but no host was provided to "
                "verify against; refusing to connect (use the insecure override "
                "to disable verification)");
        return NULL;
    }
    uint8_t* wire = NULL;
    unsigned int wire_len = 0;
    if (build_alpn_wire(alpn_csv, &wire, &wire_len) != 0) {
        set_err("malformed ALPN protocol list");
        return NULL;
    }
    unsigned long alpn_size = 0;
    uint8_t* alpn = wire ? alpn_sspi_buffer(wire, wire_len, &alpn_size) : NULL;
    free(wire);
    /* An IP-literal host is not sent as SNI (RFC 6066) and is matched
     * against the certificate's iPAddress names by the runtime. */
    uint8_t ip[16];
    int ip_len = has_host ? ip_literal(sni_host, ip) : 0;
    wchar_t* target = has_host && !ip_len ? lyric_win32_wide(sni_host) : NULL;
    if (has_host && !ip_len && !target) {
        free(alpn);
        set_err("the host name is not valid UTF-8");
        return NULL;
    }
    if (ensure_cred(c) != 0) {
        free(alpn);
        free(target);
        return NULL;
    }
    TlsConn* t = conn_new(c, fd);
    if (!t || handshake(t, target, alpn, alpn_size) != 0 || finish_handshake(t) != 0) {
        free(alpn);
        free(target);
        if (t) conn_free(t);
        return NULL;
    }
    free(alpn);
    if (!c->insecure) {
        PCCERT_CONTEXT peer = NULL;
        SECURITY_STATUS st = QueryContextAttributesW(&t->h, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &peer);
        DWORD verdict = st == SEC_E_OK && peer ? check_peer(c, peer, target) : (DWORD)CERT_E_UNTRUSTEDROOT;
        if (verdict == 0 && ip_len && !cert_has_ip(peer, ip, ip_len)) verdict = (DWORD)CERT_E_CN_NO_MATCH;
        if (peer) CertFreeCertificateContext(peer);
        if (verdict != 0) {
            char msg[200];
            lyric_win32_message(verdict, msg, sizeof msg);
            set_err("certificate verification failed: %s", msg);
            free(target);
            conn_free(t);
            return NULL;
        }
    }
    free(target);
    return t;
}

void* lyric_tls_server_accept(void* raw, int32_t fd) {
    TlsCtx* c = (TlsCtx*)raw;
    if (!c || !c->is_server) return NULL;
    unsigned long alpn_size = 0;
    uint8_t* alpn = c->alpn_wire ? alpn_sspi_buffer(c->alpn_wire, c->alpn_len, &alpn_size) : NULL;
    TlsConn* t = conn_new(c, fd);
    int ok = t && handshake(t, NULL, alpn, alpn_size) == 0 && finish_handshake(t) == 0;
    free(alpn);
    if (!ok) {
        if (t) conn_free(t);
        return NULL;
    }
    if (c->verify_client) {
        PCCERT_CONTEXT peer = NULL;
        SECURITY_STATUS st = QueryContextAttributesW(&t->h, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &peer);
        if (st != SEC_E_OK || !peer) {
            if (c->require_client_cert) {
                set_err("TLS handshake: the client presented no certificate");
                conn_free(t);
                return NULL;
            }
        } else {
            DWORD verdict = check_chain(c->engine, peer, 0, NULL);
            CertFreeCertificateContext(peer);
            if (verdict != 0) {
                char msg[200];
                lyric_win32_message(verdict, msg, sizeof msg);
                set_err("TLS handshake: client certificate verification failed: %s", msg);
                conn_free(t);
                return NULL;
            }
        }
    }
    return t;
}

/* ── Records ───────────────────────────────────────────────────────── */

/* Decrypts one record from `in` into `plain`.  1 when progress was made
 * (bytes, possibly none, or a post-handshake message processed), 0 when
 * more input is needed, 2 at close_notify, -1 on error.  A TLS 1.3
 * post-handshake message (a session ticket, a key update) comes back as
 * SEC_I_RENEGOTIATE and is handed to the handshake function, which may in
 * turn need more input. */
static int decrypt_one(TlsConn* t) {
    if (t->renegotiating) {
        int send_failed = 0;
        SECURITY_STATUS st = step(t, NULL, NULL, 0, "TLS read", &send_failed);
        if (FAILED(st) && st != SEC_E_INCOMPLETE_MESSAGE) {
            set_status_err("TLS read", st);
            return -1;
        }
        if (send_failed) return -1;
        if (st == SEC_E_INCOMPLETE_MESSAGE) return 0;
        if (st == SEC_E_OK) t->renegotiating = 0;
        return 1;
    }
    if (t->in_len == 0) return 0;
    SecBuffer b[4];
    b[0].BufferType = SECBUFFER_DATA;
    b[0].pvBuffer = t->in;
    b[0].cbBuffer = (unsigned long)t->in_len;
    for (int i = 1; i < 4; i++) {
        b[i].BufferType = SECBUFFER_EMPTY;
        b[i].pvBuffer = NULL;
        b[i].cbBuffer = 0;
    }
    SecBufferDesc desc = {SECBUFFER_VERSION, 4, b};
    SECURITY_STATUS st = DecryptMessage(&t->h, &desc, 0, NULL);
    if (st == SEC_E_INCOMPLETE_MESSAGE) return 0;
    if (st == SEC_I_CONTEXT_EXPIRED) return 2;
    if (st != SEC_E_OK && st != SEC_I_RENEGOTIATE) {
        set_status_err("TLS read", st);
        return -1;
    }
    SecBuffer* data = NULL;
    SecBuffer* extra = NULL;
    for (int i = 0; i < 4; i++) {
        if (b[i].BufferType == SECBUFFER_DATA && !data) data = &b[i];
        if (b[i].BufferType == SECBUFFER_EXTRA && !extra) extra = &b[i];
    }
    if (data && data->cbBuffer > 0) {
        uint8_t* p = (uint8_t*)realloc(t->plain, data->cbBuffer);
        if (!p) {
            set_err("out of memory");
            return -1;
        }
        t->plain = p;
        memcpy(t->plain, data->pvBuffer, data->cbBuffer);
        t->plain_off = 0;
        t->plain_len = data->cbBuffer;
    }
    if (extra && extra->cbBuffer > 0) {
        size_t n = extra->cbBuffer;
        memmove(t->in, (uint8_t*)extra->pvBuffer, n);
        t->in_len = n;
    } else {
        t->in_len = 0;
    }
    if (st == SEC_I_RENEGOTIATE) t->renegotiating = 1;
    return 1;
}

int64_t lyric_tls_read(void* raw, uint8_t* buf, int64_t n) {
    TlsConn* t = (TlsConn*)raw;
    if (!t || n <= 0) return 0;
    for (;;) {
        if (t->plain_len > 0) {
            size_t take = (size_t)n < t->plain_len ? (size_t)n : t->plain_len;
            memcpy(buf, t->plain + t->plain_off, take);
            t->plain_off += take;
            t->plain_len -= take;
            return (int64_t)take;
        }
        if (t->eof) return 0;
        int r = decrypt_one(t);
        if (r < 0) return -1;
        if (r == 2) {
            t->eof = 1;
            return 0;
        }
        if (r == 1) continue;
        int got = recv_more(t, "TLS read");
        if (got < 0) return -1;
        if (got == 0) {
            t->eof = 1; /* the peer closed the connection */
            return 0;
        }
    }
}

int64_t lyric_tls_write(void* raw, const uint8_t* buf, int64_t n) {
    TlsConn* t = (TlsConn*)raw;
    if (!t) return -1;
    if (n <= 0) return 0;
    size_t cap = t->sizes.cbHeader + t->sizes.cbMaximumMessage + t->sizes.cbTrailer;
    uint8_t* msg = (uint8_t*)malloc(cap);
    if (!msg) {
        set_err("out of memory");
        return -1;
    }
    int64_t off = 0;
    while (off < n) {
        int64_t left = n - off;
        unsigned long chunk = left > (int64_t)t->sizes.cbMaximumMessage ? t->sizes.cbMaximumMessage : (unsigned long)left;
        memcpy(msg + t->sizes.cbHeader, buf + off, chunk);
        SecBuffer b[4];
        b[0].BufferType = SECBUFFER_STREAM_HEADER;
        b[0].pvBuffer = msg;
        b[0].cbBuffer = t->sizes.cbHeader;
        b[1].BufferType = SECBUFFER_DATA;
        b[1].pvBuffer = msg + t->sizes.cbHeader;
        b[1].cbBuffer = chunk;
        b[2].BufferType = SECBUFFER_STREAM_TRAILER;
        b[2].pvBuffer = msg + t->sizes.cbHeader + chunk;
        b[2].cbBuffer = t->sizes.cbTrailer;
        b[3].BufferType = SECBUFFER_EMPTY;
        b[3].pvBuffer = NULL;
        b[3].cbBuffer = 0;
        SecBufferDesc desc = {SECBUFFER_VERSION, 4, b};
        SECURITY_STATUS st = EncryptMessage(&t->h, 0, &desc, 0);
        if (st != SEC_E_OK) {
            free(msg);
            set_status_err("TLS write", st);
            return -1;
        }
        if (send_all(t->s, msg, (size_t)b[0].cbBuffer + b[1].cbBuffer + b[2].cbBuffer, "TLS write") != 0) {
            free(msg);
            return -1;
        }
        off += chunk;
    }
    free(msg);
    return n;
}

LyricList* lyric_tls_read_bytes(void* conn, int64_t max_bytes, int32_t* ok) {
    LyricList* list = lyric_list_new(0);
    if (max_bytes <= 0) {
        *ok = 1;
        return list;
    }
    uint8_t* buf = (uint8_t*)malloc((size_t)max_bytes);
    if (!buf) {
        set_err("out of memory");
        *ok = 0;
        return list;
    }
    int64_t n = lyric_tls_read(conn, buf, max_bytes);
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

int64_t lyric_tls_write_bytes(void* conn, void* bytes_list) {
    LyricList* list = (LyricList*)bytes_list;
    int64_t n = list ? list->len : 0;
    if (n <= 0) return 0;
    uint8_t* buf = (uint8_t*)malloc((size_t)n);
    if (!buf) {
        set_err("out of memory");
        return -1;
    }
    for (int64_t i = 0; i < n; i++) buf[i] = (uint8_t)(list->data[i] & 0xff);
    int64_t rc = lyric_tls_write(conn, buf, n);
    free(buf);
    return rc;
}

int32_t lyric_tls_alpn(void* raw, char* out, int32_t out_cap) {
    TlsConn* t = (TlsConn*)raw;
    if (!t || !out || out_cap <= 0) return 0;
    size_t n = strlen(t->alpn);
    if (n > (size_t)(out_cap - 1)) n = (size_t)(out_cap - 1);
    memcpy(out, t->alpn, n);
    out[n] = '\0';
    return (int32_t)n;
}

LyricString* lyric_tls_alpn_string(void* conn) {
    char buf[256];
    int32_t n = lyric_tls_alpn(conn, buf, (int32_t)sizeof buf);
    return lyric_string_from_literal((const uint8_t*)buf, (int64_t)n);
}

/* Sends close_notify (best effort). */
void lyric_tls_shutdown(void* raw) {
    TlsConn* t = (TlsConn*)raw;
    if (!t || !t->have_h) return;
    DWORD type = SCHANNEL_SHUTDOWN;
    SecBuffer b = {sizeof type, SECBUFFER_TOKEN, &type};
    SecBufferDesc desc = {SECBUFFER_VERSION, 1, &b};
    if (ApplyControlToken(&t->h, &desc) != SEC_E_OK) return;
    SecBuffer out = {0, SECBUFFER_TOKEN, NULL};
    SecBufferDesc out_desc = {SECBUFFER_VERSION, 1, &out};
    ULONG attrs = 0;
    TlsCtx* c = t->ctx;
    if (c->is_server) {
        AcceptSecurityContext(&c->cred, &t->h, NULL,
                              ASC_REQ_SEQUENCE_DETECT | ASC_REQ_REPLAY_DETECT | ASC_REQ_CONFIDENTIALITY |
                                  ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_STREAM,
                              0, &t->h, &out_desc, &attrs, NULL);
    } else {
        InitializeSecurityContextW(&c->cred, &t->h, NULL,
                                   ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY |
                                       ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM,
                                   0, 0, NULL, 0, &t->h, &out_desc, &attrs, NULL);
    }
    (void)flush_tokens(t, &out, 1, "TLS shutdown");
}

void lyric_tls_free(void* raw) {
    if (raw) conn_free((TlsConn*)raw);
}
