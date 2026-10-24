/* lyric_wasmhost.c — the in-process wasmtime embedding behind Std.Plugin's
 * component mode (docs/69 §9.3, contract §3/§4 of phase P5).
 *
 * Layers, top to bottom:
 *   * the public API in lyric_wasmhost.h: components, instances, calls;
 *   * the generic JSON <-> component-value conversion, driven by the
 *     function types wasmtime reports and the component's type hints;
 *   * a small JSON reader and writer;
 *   * the run-time loader for libwasmtime (dlopen/dlsym into a table of
 *     function pointers, the lyric_tls.c pattern), so neither lyric_rt.a nor
 *     liblyric_wasmhost has a link-time dependency on wasmtime.
 *
 * The wasmtime declarations come from the vendored v49.0.3 headers in
 * third_party/wasmtime; only their types and the function prototypes (for
 * __typeof__) are used, never the symbols themselves.
 *
 * Isolation: one engine per process (epoch interruption on, signal-based
 * traps off so the shim coexists with the CLR's and the JVM's own signal
 * handlers), one store per instance with a memory limiter, and a WASI p2
 * context that grants nothing but an inherited stderr.  Timeouts: a ticker
 * thread bumps the engine epoch every LWH_TICK_MS while a call is running;
 * each store's epoch callback compares the monotonic clock with the call's
 * deadline and stops the guest once it has passed.
 */
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include "lyric_wasmhost.h"

#include <wasi.h>
#include <wasm.h>
#include <wasmtime.h>

#include <dlfcn.h>
#include <errno.h>
#include <locale.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(__APPLE__)
#include <xlocale.h>
#endif

#define LWH_TICK_MS 5

/* ── Errors ─────────────────────────────────────────────────────────────── */

static _Thread_local char g_last_error[1024];

static void set_error(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_last_error, sizeof(g_last_error), fmt, ap);
    va_end(ap);
}

LYRIC_WASMHOST_API char* lyric_wasmhost_alloc(int64_t size) {
    if (size <= 0) size = 1;
    return (char*)malloc((size_t)size);
}

LYRIC_WASMHOST_API void lyric_wasmhost_free(char* p) { free(p); }

static char* dup_cstr(const char* s) {
    size_t n = strlen(s);
    char* r = lyric_wasmhost_alloc((int64_t)n + 1);
    if (r) memcpy(r, s, n + 1);
    return r;
}

/* ── The libwasmtime loader ─────────────────────────────────────────────── */

#define LWH_FUNCS(X)                                  \
    X(wasm_config_new)                                \
    X(wasm_engine_new_with_config)                    \
    X(wasm_byte_vec_new)                              \
    X(wasm_byte_vec_new_empty)                        \
    X(wasm_byte_vec_delete)                           \
    X(wasmtime_config_epoch_interruption_set)         \
    X(wasmtime_config_signals_based_traps_set)        \
    X(wasmtime_engine_increment_epoch)                \
    X(wasmtime_error_new)                             \
    X(wasmtime_error_message)                         \
    X(wasmtime_error_delete)                          \
    X(wasmtime_error_wasm_trace)                      \
    X(wasm_frame_vec_delete)                          \
    X(wasmtime_store_new)                             \
    X(wasmtime_store_context)                         \
    X(wasmtime_store_limiter)                         \
    X(wasmtime_store_delete)                          \
    X(wasmtime_store_epoch_deadline_callback)         \
    X(wasmtime_context_get_data)                      \
    X(wasmtime_context_set_wasi)                      \
    X(wasmtime_context_set_epoch_deadline)            \
    X(wasi_config_new)                                \
    X(wasi_config_inherit_stderr)                     \
    X(wasmtime_component_new)                         \
    X(wasmtime_component_delete)                      \
    X(wasmtime_component_type)                        \
    X(wasmtime_component_type_delete)                 \
    X(wasmtime_component_type_import_count)           \
    X(wasmtime_component_type_import_nth)             \
    X(wasmtime_component_type_export_count)           \
    X(wasmtime_component_type_export_nth)             \
    X(wasmtime_component_instance_type_export_count)  \
    X(wasmtime_component_instance_type_export_nth)    \
    X(wasmtime_component_extern_type)                 \
    X(wasmtime_component_extern_delete)               \
    X(wasmtime_component_item_delete)                 \
    X(wasmtime_component_get_export_index)            \
    X(wasmtime_component_export_index_delete)         \
    X(wasmtime_component_linker_new)                  \
    X(wasmtime_component_linker_delete)               \
    X(wasmtime_component_linker_root)                 \
    X(wasmtime_component_linker_add_wasip2)           \
    X(wasmtime_component_linker_instantiate)          \
    X(wasmtime_component_linker_instance_add_instance) \
    X(wasmtime_component_linker_instance_add_func)    \
    X(wasmtime_component_linker_instance_delete)      \
    X(wasmtime_component_instance_get_func)           \
    X(wasmtime_component_func_type)                   \
    X(wasmtime_component_func_type_delete)            \
    X(wasmtime_component_func_type_param_count)       \
    X(wasmtime_component_func_type_param_nth)         \
    X(wasmtime_component_func_type_result)            \
    X(wasmtime_component_func_call)                   \
    X(wasmtime_component_func_post_return)            \
    X(wasmtime_component_valtype_delete)              \
    X(wasmtime_component_list_type_element)           \
    X(wasmtime_component_record_type_field_count)     \
    X(wasmtime_component_record_type_field_nth)       \
    X(wasmtime_component_tuple_type_types_count)      \
    X(wasmtime_component_tuple_type_types_nth)        \
    X(wasmtime_component_variant_type_case_count)     \
    X(wasmtime_component_variant_type_case_nth)       \
    X(wasmtime_component_enum_type_names_count)       \
    X(wasmtime_component_enum_type_names_nth)         \
    X(wasmtime_component_option_type_ty)              \
    X(wasmtime_component_result_type_ok)              \
    X(wasmtime_component_result_type_err)             \
    X(wasmtime_component_flags_type_names_count)      \
    X(wasmtime_component_flags_type_names_nth)        \
    X(wasmtime_component_map_type_key)                \
    X(wasmtime_component_map_type_value)              \
    X(wasmtime_component_vallist_new_uninit)          \
    X(wasmtime_component_valrecord_new_uninit)        \
    X(wasmtime_component_valtuple_new_uninit)         \
    X(wasmtime_component_valflags_new_uninit)         \
    X(wasmtime_component_valmap_new_uninit)           \
    X(wasmtime_component_val_new)                     \
    X(wasmtime_component_val_delete)

#define LWH_DECLARE(name) static __typeof__(&name) p_##name;
LWH_FUNCS(LWH_DECLARE)
#undef LWH_DECLARE

static pthread_once_t g_load_once = PTHREAD_ONCE_INIT;
static bool g_loaded;
static char g_unavailable[1024];
static wasm_engine_t* g_engine;

#if defined(__APPLE__)
#define LWH_WASMTIME_FILE "libwasmtime.dylib"
#else
#define LWH_WASMTIME_FILE "libwasmtime.so"
#endif

/* The directory holding this code: the shared shim, or the executable that
 * links lyric_rt.a statically. */
static bool own_dir(char* out, size_t cap) {
    Dl_info info;
    if (dladdr((void*)&lyric_wasmhost_available, &info) == 0 || info.dli_fname == NULL) return false;
    const char* slash = strrchr(info.dli_fname, '/');
    if (slash == NULL) return false;
    size_t n = (size_t)(slash - info.dli_fname);
    if (n + 1 > cap) return false;
    memcpy(out, info.dli_fname, n);
    out[n] = '\0';
    return true;
}

static void load_wasmtime(void) {
    void* h = NULL;
    const char* explicit_path = getenv("LYRIC_WASMTIME_LIB");
    if (explicit_path != NULL && explicit_path[0] != '\0') {
        h = dlopen(explicit_path, RTLD_NOW | RTLD_LOCAL);
        if (h == NULL) {
            snprintf(g_unavailable, sizeof(g_unavailable), "$LYRIC_WASMTIME_LIB names '%s', which could not be loaded: %s",
                     explicit_path, dlerror());
            return;
        }
    } else {
        char dir[4096];
        char path[4200];
        if (own_dir(dir, sizeof(dir))) {
            snprintf(path, sizeof(path), "%s/%s", dir, LWH_WASMTIME_FILE);
            h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        }
        if (h == NULL) h = dlopen(LWH_WASMTIME_FILE, RTLD_NOW | RTLD_LOCAL);
        if (h == NULL) {
            snprintf(g_unavailable, sizeof(g_unavailable),
                     "in-process wasm needs %s (wasmtime 49 C API) at $LYRIC_WASMTIME_LIB, next to the host, or on "
                     "the loader path: %s",
                     LWH_WASMTIME_FILE, dlerror());
            return;
        }
    }
#define LWH_RESOLVE(name)                                                                                 \
    p_##name = (__typeof__(&name))dlsym(h, #name);                                                        \
    if (p_##name == NULL) {                                                                               \
        snprintf(g_unavailable, sizeof(g_unavailable), "the loaded wasmtime library has no symbol %s (wasmtime " \
                 "49.0.3 is required)", #name);                                                           \
        dlclose(h);                                                                                       \
        return;                                                                                           \
    }
    LWH_FUNCS(LWH_RESOLVE)
#undef LWH_RESOLVE
    wasm_config_t* config = p_wasm_config_new();
    if (config == NULL) {
        snprintf(g_unavailable, sizeof(g_unavailable), "wasmtime could not create an engine configuration");
        return;
    }
    p_wasmtime_config_epoch_interruption_set(config, true);
    /* The CLR and the JVM handle SIGSEGV themselves; explicit bounds checks
     * keep wasmtime out of the host runtime's signal handling. */
    p_wasmtime_config_signals_based_traps_set(config, false);
    g_engine = p_wasm_engine_new_with_config(config);
    if (g_engine == NULL) {
        snprintf(g_unavailable, sizeof(g_unavailable), "wasmtime could not create an engine");
        return;
    }
    g_loaded = true;
}

static bool ensure_loaded(void) {
    pthread_once(&g_load_once, load_wasmtime);
    if (!g_loaded) set_error("%s", g_unavailable);
    return g_loaded;
}

LYRIC_WASMHOST_API int32_t lyric_wasmhost_available(void) { return ensure_loaded() ? 1 : 0; }

LYRIC_WASMHOST_API char* lyric_wasmhost_unavailable_reason(void) {
    ensure_loaded();
    return dup_cstr(g_loaded ? "" : g_unavailable);
}

LYRIC_WASMHOST_API char* lyric_wasmhost_last_error(void) { return dup_cstr(g_last_error); }

static void take_error_message(wasmtime_error_t* err, char* out, size_t cap) {
    wasm_name_t msg;
    p_wasmtime_error_message(err, &msg);
    size_t n = msg.size < cap - 1 ? msg.size : cap - 1;
    if (n > 0) memcpy(out, msg.data, n);
    out[n] = '\0';
    p_wasm_byte_vec_delete(&msg);
    p_wasmtime_error_delete(err);
}

/* ── Clock and the epoch ticker ─────────────────────────────────────────── */

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static pthread_mutex_t g_tick_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_tick_cv = PTHREAD_COND_INITIALIZER;
static int g_running_calls;
static bool g_ticker_started;

static void* ticker_main(void* arg) {
    (void)arg;
    pthread_mutex_lock(&g_tick_mu);
    for (;;) {
        while (g_running_calls == 0) pthread_cond_wait(&g_tick_cv, &g_tick_mu);
        pthread_mutex_unlock(&g_tick_mu);
        struct timespec d = {0, LWH_TICK_MS * 1000000L};
        while (nanosleep(&d, &d) != 0 && errno == EINTR) {
        }
        p_wasmtime_engine_increment_epoch(g_engine);
        pthread_mutex_lock(&g_tick_mu);
    }
    return NULL;
}

static bool running_begin(void) {
    pthread_mutex_lock(&g_tick_mu);
    if (!g_ticker_started) {
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        int rc = pthread_create(&t, &attr, ticker_main, NULL);
        pthread_attr_destroy(&attr);
        if (rc != 0) {
            pthread_mutex_unlock(&g_tick_mu);
            set_error("could not start the wasm timeout thread: %s", strerror(rc));
            return false;
        }
        g_ticker_started = true;
    }
    g_running_calls++;
    pthread_cond_signal(&g_tick_cv);
    pthread_mutex_unlock(&g_tick_mu);
    return true;
}

static void running_end(void) {
    pthread_mutex_lock(&g_tick_mu);
    g_running_calls--;
    pthread_mutex_unlock(&g_tick_mu);
}

/* ── Locale-independent numbers ─────────────────────────────────────────── */

static locale_t g_c_locale;
static pthread_once_t g_c_locale_once = PTHREAD_ONCE_INIT;

static void init_c_locale(void) { g_c_locale = newlocale(LC_NUMERIC_MASK, "C", (locale_t)0); }

/* The "C" numeric locale, so a host that called setlocale (the CLR does)
 * still reads and writes JSON numbers with a '.'.  When newlocale fails this
 * is (locale_t)0, and uselocale(0) leaves the thread's locale unchanged. */
static locale_t c_locale(void) {
    pthread_once(&g_c_locale_once, init_c_locale);
    return g_c_locale;
}

static double parse_double(const char* s, size_t n, bool* ok) {
    char buf[64];
    if (n >= sizeof(buf)) {
        *ok = false;
        return 0;
    }
    memcpy(buf, s, n);
    buf[n] = '\0';
    locale_t prev = uselocale(c_locale());
    char* end = NULL;
    errno = 0;
    double d = strtod(buf, &end);
    uselocale(prev);
    *ok = end == buf + n;
    return d;
}

/* ── String builder ─────────────────────────────────────────────────────── */

typedef struct {
    char* p;
    size_t n;
    size_t cap;
    bool oom;
} Sb;

static void sb_reserve(Sb* sb, size_t extra) {
    if (sb->oom) return;
    if (sb->n + extra + 1 <= sb->cap) return;
    size_t cap = sb->cap ? sb->cap : 256;
    while (cap < sb->n + extra + 1) cap *= 2;
    char* p = (char*)realloc(sb->p, cap);
    if (p == NULL) {
        sb->oom = true;
        return;
    }
    sb->p = p;
    sb->cap = cap;
}

static void sb_put(Sb* sb, const char* s, size_t n) {
    sb_reserve(sb, n);
    if (sb->oom) return;
    memcpy(sb->p + sb->n, s, n);
    sb->n += n;
    sb->p[sb->n] = '\0';
}

static void sb_puts(Sb* sb, const char* s) { sb_put(sb, s, strlen(s)); }

static void sb_printf(Sb* sb, const char* fmt, ...) {
    char buf[64];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) sb_put(sb, buf, (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1);
}

static void sb_json_string(Sb* sb, const char* s, size_t n) {
    static const char hex[] = "0123456789abcdef";
    sb_put(sb, "\"", 1);
    size_t start = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c >= 0x20 && c != '"' && c != '\\') continue;
        sb_put(sb, s + start, i - start);
        switch (c) {
        case '"': sb_put(sb, "\\\"", 2); break;
        case '\\': sb_put(sb, "\\\\", 2); break;
        case '\n': sb_put(sb, "\\n", 2); break;
        case '\r': sb_put(sb, "\\r", 2); break;
        case '\t': sb_put(sb, "\\t", 2); break;
        case '\b': sb_put(sb, "\\b", 2); break;
        case '\f': sb_put(sb, "\\f", 2); break;
        default: {
            char u[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
            sb_put(sb, u, 6);
        }
        }
        start = i + 1;
    }
    sb_put(sb, s + start, n - start);
    sb_put(sb, "\"", 1);
}

static void sb_double(Sb* sb, double d, bool single) {
    if (d != d || d > 1.7976931348623157e308 || d < -1.7976931348623157e308) {
        /* JSON has no NaN or infinity. */
        sb_puts(sb, "null");
        return;
    }
    char buf[64];
    locale_t prev = uselocale(c_locale());
    snprintf(buf, sizeof(buf), single ? "%.9g" : "%.17g", d);
    uselocale(prev);
    sb_puts(sb, buf);
}

/* An envelope `{"<key>": "<message>"}`. */
static char* envelope_message(const char* key, const char* msg) {
    Sb sb = {0};
    sb_puts(&sb, "{\"");
    sb_puts(&sb, key);
    sb_puts(&sb, "\":");
    sb_json_string(&sb, msg, strlen(msg));
    sb_puts(&sb, "}");
    if (sb.oom) {
        free(sb.p);
        return dup_cstr("{\"invalid\":\"out of memory\"}");
    }
    char* r = dup_cstr(sb.p);
    free(sb.p);
    return r;
}

/* ── JSON reader ────────────────────────────────────────────────────────── */

typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } JKind;

typedef struct JNode JNode;
struct JNode {
    JKind kind;
    bool b;
    char* s; /* J_STR: the decoded bytes; J_NUM: the literal text */
    size_t slen;
    size_t count;  /* J_ARR / J_OBJ */
    JNode* items;  /* children */
    char** keys;   /* J_OBJ: member names (decoded, NUL-terminated) */
    size_t* klens;
};

typedef struct {
    const char* p;
    const char* end;
    const char* err;
    int depth;
} JParser;

static void jfree(JNode* n) {
    if (n == NULL) return;
    free(n->s);
    for (size_t i = 0; i < n->count; i++) {
        jfree(&n->items[i]);
        if (n->keys) free(n->keys[i]);
    }
    free(n->items);
    free(n->keys);
    free(n->klens);
    memset(n, 0, sizeof(*n));
}

static void jskip_ws(JParser* jp) {
    while (jp->p < jp->end && (*jp->p == ' ' || *jp->p == '\t' || *jp->p == '\n' || *jp->p == '\r')) jp->p++;
}

static void put_utf8(Sb* sb, uint32_t cp) {
    char b[4];
    size_t n;
    if (cp < 0x80) {
        b[0] = (char)cp;
        n = 1;
    } else if (cp < 0x800) {
        b[0] = (char)(0xC0 | (cp >> 6));
        b[1] = (char)(0x80 | (cp & 0x3F));
        n = 2;
    } else if (cp < 0x10000) {
        b[0] = (char)(0xE0 | (cp >> 12));
        b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (char)(0x80 | (cp & 0x3F));
        n = 3;
    } else {
        b[0] = (char)(0xF0 | (cp >> 18));
        b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[3] = (char)(0x80 | (cp & 0x3F));
        n = 4;
    }
    sb_put(sb, b, n);
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool jread_hex4(JParser* jp, uint32_t* out) {
    if (jp->end - jp->p < 4) return false;
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        int h = hexval(jp->p[i]);
        if (h < 0) return false;
        v = (v << 4) | (uint32_t)h;
    }
    jp->p += 4;
    *out = v;
    return true;
}

/* Reads a string after its opening quote into a fresh buffer. */
static bool jparse_string_raw(JParser* jp, char** out, size_t* outlen) {
    Sb sb = {0};
    sb_reserve(&sb, 16);
    for (;;) {
        if (jp->p >= jp->end) {
            jp->err = "unterminated string";
            free(sb.p);
            return false;
        }
        unsigned char c = (unsigned char)*jp->p++;
        if (c == '"') break;
        if (c < 0x20) {
            jp->err = "control character in a string";
            free(sb.p);
            return false;
        }
        if (c != '\\') {
            sb_put(&sb, (const char*)&c, 1);
            continue;
        }
        if (jp->p >= jp->end) {
            jp->err = "unterminated escape";
            free(sb.p);
            return false;
        }
        char e = *jp->p++;
        switch (e) {
        case '"': sb_put(&sb, "\"", 1); break;
        case '\\': sb_put(&sb, "\\", 1); break;
        case '/': sb_put(&sb, "/", 1); break;
        case 'b': sb_put(&sb, "\b", 1); break;
        case 'f': sb_put(&sb, "\f", 1); break;
        case 'n': sb_put(&sb, "\n", 1); break;
        case 'r': sb_put(&sb, "\r", 1); break;
        case 't': sb_put(&sb, "\t", 1); break;
        case 'u': {
            uint32_t cp;
            if (!jread_hex4(jp, &cp)) {
                jp->err = "bad \\u escape";
                free(sb.p);
                return false;
            }
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                uint32_t lo;
                if (jp->end - jp->p < 2 || jp->p[0] != '\\' || jp->p[1] != 'u') {
                    jp->err = "unpaired surrogate";
                    free(sb.p);
                    return false;
                }
                jp->p += 2;
                if (!jread_hex4(jp, &lo) || lo < 0xDC00 || lo > 0xDFFF) {
                    jp->err = "unpaired surrogate";
                    free(sb.p);
                    return false;
                }
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                jp->err = "unpaired surrogate";
                free(sb.p);
                return false;
            }
            put_utf8(&sb, cp);
            break;
        }
        default:
            jp->err = "bad escape";
            free(sb.p);
            return false;
        }
    }
    if (sb.oom) {
        jp->err = "out of memory";
        free(sb.p);
        return false;
    }
    *out = sb.p;
    *outlen = sb.n;
    return true;
}

static bool jparse_value(JParser* jp, JNode* out) {
    memset(out, 0, sizeof(*out));
    jskip_ws(jp);
    if (jp->p >= jp->end) {
        jp->err = "unexpected end of input";
        return false;
    }
    if (++jp->depth > 256) {
        jp->err = "nested too deeply";
        return false;
    }
    char c = *jp->p;
    bool ok = true;
    if (c == '{' || c == '[') {
        bool obj = c == '{';
        jp->p++;
        out->kind = obj ? J_OBJ : J_ARR;
        size_t cap = 0;
        jskip_ws(jp);
        if (jp->p < jp->end && *jp->p == (obj ? '}' : ']')) {
            jp->p++;
        } else {
            for (;;) {
                if (out->count == cap) {
                    cap = cap ? cap * 2 : 4;
                    JNode* items = (JNode*)realloc(out->items, cap * sizeof(JNode));
                    if (items == NULL) {
                        jp->err = "out of memory";
                        ok = false;
                        break;
                    }
                    out->items = items;
                    if (obj) {
                        char** keys = (char**)realloc(out->keys, cap * sizeof(char*));
                        size_t* klens = keys ? (size_t*)realloc(out->klens, cap * sizeof(size_t)) : NULL;
                        if (keys) out->keys = keys;
                        if (klens) out->klens = klens;
                        if (keys == NULL || klens == NULL) {
                            jp->err = "out of memory";
                            ok = false;
                            break;
                        }
                    }
                }
                if (obj) {
                    jskip_ws(jp);
                    if (jp->p >= jp->end || *jp->p != '"') {
                        jp->err = "expected a member name";
                        ok = false;
                        break;
                    }
                    jp->p++;
                    char* key;
                    size_t klen;
                    if (!jparse_string_raw(jp, &key, &klen)) {
                        ok = false;
                        break;
                    }
                    jskip_ws(jp);
                    if (jp->p >= jp->end || *jp->p != ':') {
                        free(key);
                        jp->err = "expected ':'";
                        ok = false;
                        break;
                    }
                    jp->p++;
                    out->keys[out->count] = key;
                    out->klens[out->count] = klen;
                }
                if (!jparse_value(jp, &out->items[out->count])) {
                    if (obj) free(out->keys[out->count]);
                    ok = false;
                    break;
                }
                out->count++;
                jskip_ws(jp);
                if (jp->p < jp->end && *jp->p == ',') {
                    jp->p++;
                    continue;
                }
                if (jp->p < jp->end && *jp->p == (obj ? '}' : ']')) {
                    jp->p++;
                    break;
                }
                jp->err = obj ? "expected ',' or '}'" : "expected ',' or ']'";
                ok = false;
                break;
            }
        }
    } else if (c == '"') {
        jp->p++;
        out->kind = J_STR;
        ok = jparse_string_raw(jp, &out->s, &out->slen);
    } else if (c == 't' && jp->end - jp->p >= 4 && memcmp(jp->p, "true", 4) == 0) {
        out->kind = J_BOOL;
        out->b = true;
        jp->p += 4;
    } else if (c == 'f' && jp->end - jp->p >= 5 && memcmp(jp->p, "false", 5) == 0) {
        out->kind = J_BOOL;
        jp->p += 5;
    } else if (c == 'n' && jp->end - jp->p >= 4 && memcmp(jp->p, "null", 4) == 0) {
        out->kind = J_NULL;
        jp->p += 4;
    } else if (c == '-' || (c >= '0' && c <= '9')) {
        const char* start = jp->p;
        if (*jp->p == '-') jp->p++;
        if (jp->p >= jp->end || !(*jp->p >= '0' && *jp->p <= '9')) {
            jp->err = "bad number";
            ok = false;
        } else {
            if (*jp->p == '0') {
                jp->p++;
            } else {
                while (jp->p < jp->end && *jp->p >= '0' && *jp->p <= '9') jp->p++;
            }
            if (jp->p < jp->end && *jp->p == '.') {
                jp->p++;
                if (jp->p >= jp->end || !(*jp->p >= '0' && *jp->p <= '9')) ok = false;
                while (jp->p < jp->end && *jp->p >= '0' && *jp->p <= '9') jp->p++;
            }
            if (ok && jp->p < jp->end && (*jp->p == 'e' || *jp->p == 'E')) {
                jp->p++;
                if (jp->p < jp->end && (*jp->p == '+' || *jp->p == '-')) jp->p++;
                if (jp->p >= jp->end || !(*jp->p >= '0' && *jp->p <= '9')) ok = false;
                while (jp->p < jp->end && *jp->p >= '0' && *jp->p <= '9') jp->p++;
            }
            if (!ok) {
                jp->err = "bad number";
            } else {
                out->kind = J_NUM;
                out->slen = (size_t)(jp->p - start);
                out->s = (char*)malloc(out->slen + 1);
                if (out->s == NULL) {
                    jp->err = "out of memory";
                    ok = false;
                } else {
                    memcpy(out->s, start, out->slen);
                    out->s[out->slen] = '\0';
                }
            }
        }
    } else {
        jp->err = "unexpected character";
        ok = false;
    }
    jp->depth--;
    if (!ok) jfree(out);
    return ok;
}

/* Parses `text` as one JSON value.  On failure returns false and writes a
 * description into `err`. */
static bool jparse(const char* text, JNode* out, char* err, size_t errcap) {
    JParser jp = {text, text + strlen(text), NULL, 0};
    if (!jparse_value(&jp, out)) {
        snprintf(err, errcap, "malformed JSON at offset %zu: %s", (size_t)(jp.p - text), jp.err ? jp.err : "error");
        return false;
    }
    jskip_ws(&jp);
    if (jp.p != jp.end) {
        jfree(out);
        snprintf(err, errcap, "malformed JSON at offset %zu: trailing characters", (size_t)(jp.p - text));
        return false;
    }
    return true;
}

static const JNode* jget(const JNode* obj, const char* key) {
    if (obj == NULL || obj->kind != J_OBJ) return NULL;
    size_t klen = strlen(key);
    for (size_t i = 0; i < obj->count; i++) {
        if (obj->klens[i] == klen && memcmp(obj->keys[i], key, klen) == 0) return &obj->items[i];
    }
    return NULL;
}

static const JNode* jget_n(const JNode* obj, const char* key, size_t klen) {
    if (obj == NULL || obj->kind != J_OBJ) return NULL;
    for (size_t i = 0; i < obj->count; i++) {
        if (obj->klens[i] == klen && memcmp(obj->keys[i], key, klen) == 0) return &obj->items[i];
    }
    return NULL;
}

/* A hint member (`{"record": ...}` and so on); NULL when absent or null. */
static const JNode* hint_part(const JNode* hint, const char* key) {
    const JNode* h = jget(hint, key);
    return (h == NULL || h->kind == J_NULL) ? NULL : h;
}

static const char* jkind_name(const JNode* n) {
    switch (n->kind) {
    case J_NULL: return "null";
    case J_BOOL: return "a boolean";
    case J_NUM: return "a number";
    case J_STR: return "a string";
    case J_ARR: return "an array";
    case J_OBJ: return "an object";
    }
    return "a value";
}

/* ── Names ──────────────────────────────────────────────────────────────── */

/* WIT kebab-case to the Lyric spelling: `camel` lowercases nothing and
 * capitalises the first letter of every segment after the first; `pascal`
 * capitalises every segment.  A leading `%` (a keyword escape) is dropped. */
static void wit_to_lyric(const char* wit, size_t n, bool pascal, Sb* out) {
    if (n > 0 && wit[0] == '%') {
        wit++;
        n--;
    }
    bool up = pascal;
    for (size_t i = 0; i < n; i++) {
        char c = wit[i];
        if (c == '-') {
            up = true;
            continue;
        }
        if (up && c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
        up = false;
        sb_put(out, &c, 1);
    }
    if (out->p == NULL) sb_put(out, "", 0);
}

static bool name_eq_lyric(const char* wit, size_t n, bool pascal, const char* lyric, size_t ln) {
    Sb sb = {0};
    wit_to_lyric(wit, n, pascal, &sb);
    bool eq = !sb.oom && sb.n == ln && memcmp(sb.p, lyric, ln) == 0;
    free(sb.p);
    return eq;
}

/* ── base64 ─────────────────────────────────────────────────────────────── */

static const char b64chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void sb_base64(Sb* sb, const uint8_t* data, size_t n, size_t stride) {
    sb_put(sb, "\"", 1);
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)data[i * stride] << 16;
        if (i + 1 < n) v |= (uint32_t)data[(i + 1) * stride] << 8;
        if (i + 2 < n) v |= (uint32_t)data[(i + 2) * stride];
        char q[4] = {b64chars[(v >> 18) & 63], b64chars[(v >> 12) & 63], i + 1 < n ? b64chars[(v >> 6) & 63] : '=',
                     i + 2 < n ? b64chars[v & 63] : '='};
        sb_put(sb, q, 4);
    }
    sb_put(sb, "\"", 1);
}

static int b64val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

/* Decodes standard padded base64 into a fresh buffer. */
static bool base64_decode(const char* s, size_t n, uint8_t** out, size_t* outlen) {
    if (n % 4 != 0) return false;
    size_t cap = n / 4 * 3;
    uint8_t* buf = (uint8_t*)malloc(cap ? cap : 1);
    if (buf == NULL) return false;
    size_t o = 0;
    for (size_t i = 0; i < n; i += 4) {
        int a = b64val(s[i]), b = b64val(s[i + 1]);
        bool last = i + 4 == n;
        int c = (last && s[i + 2] == '=') ? -2 : b64val(s[i + 2]);
        int d = (last && s[i + 3] == '=') ? -2 : b64val(s[i + 3]);
        if (a < 0 || b < 0 || c == -1 || d == -1 || (c == -2 && d != -2)) {
            free(buf);
            return false;
        }
        uint32_t v = ((uint32_t)a << 18) | ((uint32_t)b << 12) | ((uint32_t)(c < 0 ? 0 : c) << 6) | (uint32_t)(d < 0 ? 0 : d);
        buf[o++] = (uint8_t)(v >> 16);
        if (c >= 0) buf[o++] = (uint8_t)(v >> 8);
        if (d >= 0) buf[o++] = (uint8_t)v;
    }
    *out = buf;
    *outlen = o;
    return true;
}

/* ── Component value -> JSON ────────────────────────────────────────────── */

typedef struct {
    char msg[512];
} Err;

static void err_set(Err* e, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(e->msg, sizeof(e->msg), fmt, ap);
    va_end(ap);
}

static bool emit_val(Sb* sb, const wasmtime_component_val_t* v, const wasmtime_component_valtype_t* ty, const JNode* hint,
                     Err* e);

static bool is_string_pair_tuple(const wasmtime_component_valtype_t* ty) {
    if (ty->kind != WASMTIME_COMPONENT_VALTYPE_TUPLE) return false;
    if (p_wasmtime_component_tuple_type_types_count(ty->of.tuple) != 2) return false;
    wasmtime_component_valtype_t first;
    if (!p_wasmtime_component_tuple_type_types_nth(ty->of.tuple, 0, &first)) return false;
    bool s = first.kind == WASMTIME_COMPONENT_VALTYPE_STRING;
    p_wasmtime_component_valtype_delete(&first);
    return s;
}

static bool emit_name(Sb* sb, const char* name, size_t n, bool pascal) {
    Sb tmp = {0};
    wit_to_lyric(name, n, pascal, &tmp);
    if (tmp.oom) {
        free(tmp.p);
        return false;
    }
    sb_json_string(sb, tmp.p, tmp.n);
    free(tmp.p);
    return true;
}

static void emit_utf8_char(Sb* sb, uint32_t cp) {
    Sb tmp = {0};
    put_utf8(&tmp, cp);
    sb_json_string(sb, tmp.p ? tmp.p : "", tmp.n);
    free(tmp.p);
}

static bool emit_list(Sb* sb, const wasmtime_component_vallist_t* list, const wasmtime_component_valtype_t* ty,
                      const JNode* hint, Err* e) {
    wasmtime_component_valtype_t elem;
    p_wasmtime_component_list_type_element(ty->of.list, &elem);
    bool ok = true;
    if (elem.kind == WASMTIME_COMPONENT_VALTYPE_U8) {
        /* List[Byte] / slice[Byte]: base64 (D207 Decision 4). */
        if (list->size == 0) {
            sb_puts(sb, "\"\"");
        } else {
            sb_base64(sb, &list->data[0].of.u8, list->size, sizeof(wasmtime_component_val_t));
        }
    } else if (jget(hint, "map") != NULL && is_string_pair_tuple(&elem)) {
        const JNode* vh = hint_part(hint, "map");
        wasmtime_component_valtype_t vt;
        p_wasmtime_component_tuple_type_types_nth(elem.of.tuple, 1, &vt);
        sb_put(sb, "{", 1);
        for (size_t i = 0; ok && i < list->size; i++) {
            const wasmtime_component_valtuple_t* t = &list->data[i].of.tuple;
            if (i > 0) sb_put(sb, ",", 1);
            sb_json_string(sb, (const char*)t->data[0].of.string.data, t->data[0].of.string.size);
            sb_put(sb, ":", 1);
            ok = emit_val(sb, &t->data[1], &vt, vh, e);
        }
        sb_put(sb, "}", 1);
        p_wasmtime_component_valtype_delete(&vt);
    } else {
        const JNode* lh = hint_part(hint, "list");
        sb_put(sb, "[", 1);
        for (size_t i = 0; ok && i < list->size; i++) {
            if (i > 0) sb_put(sb, ",", 1);
            ok = emit_val(sb, &list->data[i], &elem, lh, e);
        }
        sb_put(sb, "]", 1);
    }
    p_wasmtime_component_valtype_delete(&elem);
    return ok;
}

static bool emit_val(Sb* sb, const wasmtime_component_val_t* v, const wasmtime_component_valtype_t* ty, const JNode* hint,
                     Err* e) {
    switch (v->kind) {
    case WASMTIME_COMPONENT_BOOL: sb_puts(sb, v->of.boolean ? "true" : "false"); return true;
    case WASMTIME_COMPONENT_S8: sb_printf(sb, "%d", (int)v->of.s8); return true;
    case WASMTIME_COMPONENT_U8: sb_printf(sb, "%u", (unsigned)v->of.u8); return true;
    case WASMTIME_COMPONENT_S16: sb_printf(sb, "%d", (int)v->of.s16); return true;
    case WASMTIME_COMPONENT_U16: sb_printf(sb, "%u", (unsigned)v->of.u16); return true;
    case WASMTIME_COMPONENT_S32: sb_printf(sb, "%ld", (long)v->of.s32); return true;
    case WASMTIME_COMPONENT_U32: sb_printf(sb, "%lu", (unsigned long)v->of.u32); return true;
    case WASMTIME_COMPONENT_S64: sb_printf(sb, "%lld", (long long)v->of.s64); return true;
    case WASMTIME_COMPONENT_U64: sb_printf(sb, "%llu", (unsigned long long)v->of.u64); return true;
    case WASMTIME_COMPONENT_F32: sb_double(sb, (double)v->of.f32, true); return true;
    case WASMTIME_COMPONENT_F64: sb_double(sb, v->of.f64, false); return true;
    case WASMTIME_COMPONENT_CHAR: emit_utf8_char(sb, v->of.character); return true;
    case WASMTIME_COMPONENT_STRING:
        sb_json_string(sb, (const char*)v->of.string.data, v->of.string.size);
        return true;
    case WASMTIME_COMPONENT_LIST:
        if (ty->kind != WASMTIME_COMPONENT_VALTYPE_LIST) break;
        return emit_list(sb, &v->of.list, ty, hint, e);
    case WASMTIME_COMPONENT_RECORD: {
        if (ty->kind != WASMTIME_COMPONENT_VALTYPE_RECORD) break;
        const JNode* rh = hint_part(hint, "record");
        sb_put(sb, "{", 1);
        bool ok = true;
        for (size_t i = 0; ok && i < v->of.record.size; i++) {
            const wasmtime_component_valrecord_entry_t* ent = &v->of.record.data[i];
            const char* fname;
            size_t flen;
            wasmtime_component_valtype_t ft;
            if (!p_wasmtime_component_record_type_field_nth(ty->of.record, i, &fname, &flen, &ft)) {
                err_set(e, "a record value has more fields than its type");
                return false;
            }
            if (i > 0) sb_put(sb, ",", 1);
            emit_name(sb, (const char*)ent->name.data, ent->name.size, false);
            sb_put(sb, ":", 1);
            ok = emit_val(sb, &ent->val, &ft, jget_n(rh, (const char*)ent->name.data, ent->name.size), e);
            p_wasmtime_component_valtype_delete(&ft);
        }
        sb_put(sb, "}", 1);
        return ok;
    }
    case WASMTIME_COMPONENT_TUPLE: {
        if (ty->kind != WASMTIME_COMPONENT_VALTYPE_TUPLE) break;
        const JNode* th = hint_part(hint, "tuple");
        sb_put(sb, "[", 1);
        bool ok = true;
        for (size_t i = 0; ok && i < v->of.tuple.size; i++) {
            wasmtime_component_valtype_t et;
            if (!p_wasmtime_component_tuple_type_types_nth(ty->of.tuple, i, &et)) {
                err_set(e, "a tuple value has more elements than its type");
                return false;
            }
            if (i > 0) sb_put(sb, ",", 1);
            const JNode* eh = (th != NULL && th->kind == J_ARR && i < th->count) ? &th->items[i] : NULL;
            ok = emit_val(sb, &v->of.tuple.data[i], &et, eh, e);
            p_wasmtime_component_valtype_delete(&et);
        }
        sb_put(sb, "]", 1);
        return ok;
    }
    case WASMTIME_COMPONENT_VARIANT: {
        if (ty->kind != WASMTIME_COMPONENT_VALTYPE_VARIANT) break;
        const wasmtime_component_valvariant_t* var = &v->of.variant;
        sb_puts(sb, "{\"case\":");
        emit_name(sb, (const char*)var->discriminant.data, var->discriminant.size, true);
        if (var->val == NULL) {
            sb_put(sb, "}", 1);
            return true;
        }
        size_t nc = p_wasmtime_component_variant_type_case_count(ty->of.variant);
        for (size_t i = 0; i < nc; i++) {
            const char* cname;
            size_t clen;
            bool has_payload;
            wasmtime_component_valtype_t pt;
            if (!p_wasmtime_component_variant_type_case_nth(ty->of.variant, i, &cname, &clen, &has_payload, &pt)) break;
            if (clen != var->discriminant.size || memcmp(cname, var->discriminant.data, clen) != 0) {
                if (has_payload) p_wasmtime_component_valtype_delete(&pt);
                continue;
            }
            if (!has_payload) break;
            const JNode* ch = jget_n(hint_part(hint, "variant"), cname, clen);
            const JNode* field = hint_part(ch, "field");
            sb_put(sb, ",", 1);
            if (field != NULL && field->kind == J_STR) {
                sb_json_string(sb, field->s, field->slen);
            } else {
                sb_puts(sb, "\"value\"");
            }
            sb_put(sb, ":", 1);
            bool ok = emit_val(sb, var->val, &pt, hint_part(ch, "of"), e);
            p_wasmtime_component_valtype_delete(&pt);
            sb_put(sb, "}", 1);
            return ok;
        }
        err_set(e, "a variant value's case does not match its type");
        return false;
    }
    case WASMTIME_COMPONENT_ENUM:
        emit_name(sb, (const char*)v->of.enumeration.data, v->of.enumeration.size, true);
        return true;
    case WASMTIME_COMPONENT_OPTION: {
        if (ty->kind != WASMTIME_COMPONENT_VALTYPE_OPTION) break;
        if (v->of.option == NULL) {
            sb_puts(sb, "null");
            return true;
        }
        wasmtime_component_valtype_t it;
        p_wasmtime_component_option_type_ty(ty->of.option, &it);
        bool ok = emit_val(sb, v->of.option, &it, hint_part(hint, "option"), e);
        p_wasmtime_component_valtype_delete(&it);
        return ok;
    }
    case WASMTIME_COMPONENT_RESULT: {
        if (ty->kind != WASMTIME_COMPONENT_VALTYPE_RESULT) break;
        bool is_ok = v->of.result.is_ok;
        sb_puts(sb, is_ok ? "{\"ok\":" : "{\"err\":");
        const JNode* rh = hint_part(hint_part(hint, "result"), is_ok ? "ok" : "err");
        bool ok = true;
        if (v->of.result.val == NULL) {
            sb_puts(sb, "null");
        } else {
            wasmtime_component_valtype_t pt;
            bool has = is_ok ? p_wasmtime_component_result_type_ok(ty->of.result, &pt)
                             : p_wasmtime_component_result_type_err(ty->of.result, &pt);
            if (!has) {
                err_set(e, "a result value carries a payload its type does not have");
                return false;
            }
            ok = emit_val(sb, v->of.result.val, &pt, rh, e);
            p_wasmtime_component_valtype_delete(&pt);
        }
        sb_put(sb, "}", 1);
        return ok;
    }
    case WASMTIME_COMPONENT_FLAGS: {
        sb_put(sb, "[", 1);
        for (size_t i = 0; i < v->of.flags.size; i++) {
            if (i > 0) sb_put(sb, ",", 1);
            emit_name(sb, (const char*)v->of.flags.data[i].data, v->of.flags.data[i].size, false);
        }
        sb_put(sb, "]", 1);
        return true;
    }
    case WASMTIME_COMPONENT_MAP: {
        if (ty->kind != WASMTIME_COMPONENT_VALTYPE_MAP) break;
        wasmtime_component_valtype_t kt, vt;
        p_wasmtime_component_map_type_key(ty->of.map, &kt);
        p_wasmtime_component_map_type_value(ty->of.map, &vt);
        bool as_obj = kt.kind == WASMTIME_COMPONENT_VALTYPE_STRING;
        bool ok = true;
        sb_put(sb, as_obj ? "{" : "[", 1);
        for (size_t i = 0; ok && i < v->of.map.size; i++) {
            const wasmtime_component_valmap_entry_t* ent = &v->of.map.data[i];
            if (i > 0) sb_put(sb, ",", 1);
            if (as_obj) {
                sb_json_string(sb, (const char*)ent->key.of.string.data, ent->key.of.string.size);
                sb_put(sb, ":", 1);
            } else {
                sb_put(sb, "[", 1);
                ok = emit_val(sb, &ent->key, &kt, NULL, e);
                sb_put(sb, ",", 1);
            }
            if (ok) ok = emit_val(sb, &ent->value, &vt, hint_part(hint, "map"), e);
            if (!as_obj) sb_put(sb, "]", 1);
        }
        sb_put(sb, as_obj ? "}" : "]", 1);
        p_wasmtime_component_valtype_delete(&kt);
        p_wasmtime_component_valtype_delete(&vt);
        return ok;
    }
    case WASMTIME_COMPONENT_RESOURCE: err_set(e, "resources cannot cross the plugin boundary"); return false;
    default: break;
    }
    err_set(e, "a component value of kind %d does not match its type", (int)v->kind);
    return false;
}

/* ── JSON -> component value ────────────────────────────────────────────── */

static void val_reset(wasmtime_component_val_t* v) {
    p_wasmtime_component_val_delete(v);
    v->kind = WASMTIME_COMPONENT_BOOL;
    v->of.boolean = false;
}

static void make_name(wasm_name_t* out, const char* s, size_t n) {
    if (n == 0) {
        p_wasm_byte_vec_new_empty(out);
    } else {
        p_wasm_byte_vec_new(out, n, (const wasm_byte_t*)s);
    }
}

static bool json_int(const JNode* j, bool is_signed, int64_t lo, uint64_t hi, int64_t* sv, uint64_t* uv, const char* what,
                     Err* e) {
    if (j->kind != J_NUM) {
        err_set(e, "expected an integer for %s, got %s", what, jkind_name(j));
        return false;
    }
    for (size_t i = 0; i < j->slen; i++) {
        char c = j->s[i];
        if (c == '.' || c == 'e' || c == 'E') {
            err_set(e, "expected an integer for %s, got %s", what, j->s);
            return false;
        }
    }
    errno = 0;
    char* end = NULL;
    if (j->s[0] == '-') {
        long long x = strtoll(j->s, &end, 10);
        if (errno != 0 || *end != '\0' || !is_signed || x < lo) {
            err_set(e, "%s is out of range for %s", j->s, what);
            return false;
        }
        *sv = x;
        *uv = 0;
        return true;
    }
    unsigned long long x = strtoull(j->s, &end, 10);
    if (errno != 0 || *end != '\0' || x > hi) {
        err_set(e, "%s is out of range for %s", j->s, what);
        return false;
    }
    *uv = x;
    *sv = (int64_t)x;
    return true;
}

static bool decode_utf8_scalar(const char* s, size_t n, uint32_t* cp) {
    const unsigned char* u = (const unsigned char*)s;
    if (n == 1 && u[0] < 0x80) {
        *cp = u[0];
        return true;
    }
    if (n == 2 && (u[0] & 0xE0) == 0xC0) {
        *cp = ((uint32_t)(u[0] & 0x1F) << 6) | (u[1] & 0x3F);
        return *cp >= 0x80;
    }
    if (n == 3 && (u[0] & 0xF0) == 0xE0) {
        *cp = ((uint32_t)(u[0] & 0x0F) << 12) | ((uint32_t)(u[1] & 0x3F) << 6) | (u[2] & 0x3F);
        return *cp >= 0x800 && (*cp < 0xD800 || *cp > 0xDFFF);
    }
    if (n == 4 && (u[0] & 0xF8) == 0xF0) {
        *cp = ((uint32_t)(u[0] & 0x07) << 18) | ((uint32_t)(u[1] & 0x3F) << 12) | ((uint32_t)(u[2] & 0x3F) << 6) |
              (u[3] & 0x3F);
        return *cp >= 0x10000 && *cp <= 0x10FFFF;
    }
    return false;
}

static bool build_val(wasmtime_component_val_t* out, const JNode* j, const wasmtime_component_valtype_t* ty,
                      const JNode* hint, Err* e);

/* Builds a heap value for a variant/option/result payload. */
static bool build_boxed(wasmtime_component_val_t** out, const JNode* j, const wasmtime_component_valtype_t* ty,
                        const JNode* hint, Err* e) {
    wasmtime_component_val_t tmp;
    tmp.kind = WASMTIME_COMPONENT_BOOL;
    tmp.of.boolean = false;
    if (!build_val(&tmp, j, ty, hint, e)) return false;
    *out = p_wasmtime_component_val_new(&tmp);
    return true;
}

static bool build_list(wasmtime_component_val_t* out, const JNode* j, const wasmtime_component_valtype_t* ty,
                       const JNode* hint, Err* e) {
    wasmtime_component_valtype_t elem;
    p_wasmtime_component_list_type_element(ty->of.list, &elem);
    bool ok = true;
    out->kind = WASMTIME_COMPONENT_LIST;
    if (elem.kind == WASMTIME_COMPONENT_VALTYPE_U8 && j->kind == J_STR) {
        uint8_t* bytes;
        size_t n;
        if (!base64_decode(j->s, j->slen, &bytes, &n)) {
            err_set(e, "expected base64 for a List[Byte]");
            out->kind = WASMTIME_COMPONENT_BOOL;
            out->of.boolean = false;
            p_wasmtime_component_valtype_delete(&elem);
            return false;
        }
        p_wasmtime_component_vallist_new_uninit(&out->of.list, n);
        for (size_t i = 0; i < n; i++) {
            out->of.list.data[i].kind = WASMTIME_COMPONENT_U8;
            out->of.list.data[i].of.u8 = bytes[i];
        }
        free(bytes);
    } else if (j->kind == J_OBJ && is_string_pair_tuple(&elem)) {
        /* Map[String, T] as an object, for a list<tuple<string, T>>. */
        wasmtime_component_valtype_t vt;
        p_wasmtime_component_tuple_type_types_nth(elem.of.tuple, 1, &vt);
        const JNode* vh = hint_part(hint, "map");
        p_wasmtime_component_vallist_new_uninit(&out->of.list, j->count);
        for (size_t i = 0; i < j->count; i++) {
            wasmtime_component_val_t* t = &out->of.list.data[i];
            t->kind = WASMTIME_COMPONENT_TUPLE;
            p_wasmtime_component_valtuple_new_uninit(&t->of.tuple, 2);
            t->of.tuple.data[0].kind = WASMTIME_COMPONENT_STRING;
            make_name(&t->of.tuple.data[0].of.string, j->keys[i], j->klens[i]);
            t->of.tuple.data[1].kind = WASMTIME_COMPONENT_BOOL;
            t->of.tuple.data[1].of.boolean = false;
        }
        for (size_t i = 0; ok && i < j->count; i++) {
            ok = build_val(&out->of.list.data[i].of.tuple.data[1], &j->items[i], &vt, vh, e);
        }
        p_wasmtime_component_valtype_delete(&vt);
    } else if (j->kind == J_ARR) {
        const JNode* lh = hint_part(hint, "list");
        p_wasmtime_component_vallist_new_uninit(&out->of.list, j->count);
        for (size_t i = 0; i < j->count; i++) {
            out->of.list.data[i].kind = WASMTIME_COMPONENT_BOOL;
            out->of.list.data[i].of.boolean = false;
        }
        for (size_t i = 0; ok && i < j->count; i++) ok = build_val(&out->of.list.data[i], &j->items[i], &elem, lh, e);
    } else {
        err_set(e, "expected an array, got %s", jkind_name(j));
        out->kind = WASMTIME_COMPONENT_BOOL;
        out->of.boolean = false;
        ok = false;
    }
    p_wasmtime_component_valtype_delete(&elem);
    return ok;
}

static bool build_record(wasmtime_component_val_t* out, const JNode* j, const wasmtime_component_valtype_t* ty,
                         const JNode* hint, Err* e) {
    if (j->kind != J_OBJ) {
        err_set(e, "expected an object for a record, got %s", jkind_name(j));
        return false;
    }
    size_t n = p_wasmtime_component_record_type_field_count(ty->of.record);
    out->kind = WASMTIME_COMPONENT_RECORD;
    p_wasmtime_component_valrecord_new_uninit(&out->of.record, n);
    for (size_t i = 0; i < n; i++) {
        p_wasm_byte_vec_new_empty(&out->of.record.data[i].name);
        out->of.record.data[i].val.kind = WASMTIME_COMPONENT_BOOL;
        out->of.record.data[i].val.of.boolean = false;
    }
    const JNode* rh = hint_part(hint, "record");
    for (size_t i = 0; i < n; i++) {
        const char* fname;
        size_t flen;
        wasmtime_component_valtype_t ft;
        p_wasmtime_component_record_type_field_nth(ty->of.record, i, &fname, &flen, &ft);
        p_wasm_byte_vec_delete(&out->of.record.data[i].name);
        make_name(&out->of.record.data[i].name, fname, flen);
        Sb key = {0};
        wit_to_lyric(fname, flen, false, &key);
        const JNode* m = key.oom ? NULL : jget_n(j, key.p, key.n);
        bool ok;
        if (m == NULL && ft.kind == WASMTIME_COMPONENT_VALTYPE_OPTION) {
            out->of.record.data[i].val.kind = WASMTIME_COMPONENT_OPTION;
            out->of.record.data[i].val.of.option = NULL;
            ok = true;
        } else if (m == NULL) {
            err_set(e, "the object has no member \"%s\"", key.p ? key.p : "");
            ok = false;
        } else {
            ok = build_val(&out->of.record.data[i].val, m, &ft, jget_n(rh, fname, flen), e);
            if (!ok) {
                char inner[512];
                snprintf(inner, sizeof(inner), "%s", e->msg);
                err_set(e, "%s: %s", key.p, inner);
            }
        }
        free(key.p);
        p_wasmtime_component_valtype_delete(&ft);
        if (!ok) return false;
    }
    return true;
}

static bool build_variant(wasmtime_component_val_t* out, const JNode* j, const wasmtime_component_valtype_t* ty,
                          const JNode* hint, Err* e) {
    if (j->kind != J_OBJ) {
        err_set(e, "expected an object with a \"case\" member, got %s", jkind_name(j));
        return false;
    }
    const JNode* tag = jget(j, "case");
    if (tag == NULL || tag->kind != J_STR) {
        err_set(e, "the union object has no string \"case\" member");
        return false;
    }
    size_t nc = p_wasmtime_component_variant_type_case_count(ty->of.variant);
    for (size_t i = 0; i < nc; i++) {
        const char* cname;
        size_t clen;
        bool has_payload;
        wasmtime_component_valtype_t pt;
        p_wasmtime_component_variant_type_case_nth(ty->of.variant, i, &cname, &clen, &has_payload, &pt);
        if (!name_eq_lyric(cname, clen, true, tag->s, tag->slen)) {
            if (has_payload) p_wasmtime_component_valtype_delete(&pt);
            continue;
        }
        out->kind = WASMTIME_COMPONENT_VARIANT;
        make_name(&out->of.variant.discriminant, cname, clen);
        out->of.variant.val = NULL;
        if (!has_payload) return true;
        const JNode* ch = jget_n(hint_part(hint, "variant"), cname, clen);
        const JNode* field = hint_part(ch, "field");
        const JNode* payload = NULL;
        if (field != NULL && field->kind == J_STR) payload = jget_n(j, field->s, field->slen);
        if (payload == NULL) {
            /* The payload is the union object's one member besides "case". */
            for (size_t k = 0; k < j->count; k++) {
                if (j->klens[k] == 4 && memcmp(j->keys[k], "case", 4) == 0) continue;
                if (payload != NULL) {
                    p_wasmtime_component_valtype_delete(&pt);
                    err_set(e, "case %s carries one field, but the object has several", tag->s);
                    return false;
                }
                payload = &j->items[k];
            }
        }
        bool ok;
        if (payload == NULL) {
            err_set(e, "case %s needs its field", tag->s);
            ok = false;
        } else {
            ok = build_boxed(&out->of.variant.val, payload, &pt, hint_part(ch, "of"), e);
        }
        p_wasmtime_component_valtype_delete(&pt);
        return ok;
    }
    err_set(e, "unknown case \"%s\"", tag->s);
    return false;
}

static bool build_val(wasmtime_component_val_t* out, const JNode* j, const wasmtime_component_valtype_t* ty,
                      const JNode* hint, Err* e) {
    int64_t sv = 0;
    uint64_t uv = 0;
    bool ok = false;
    switch (ty->kind) {
    case WASMTIME_COMPONENT_VALTYPE_BOOL:
        if (j->kind != J_BOOL) {
            err_set(e, "expected a boolean, got %s", jkind_name(j));
            break;
        }
        out->kind = WASMTIME_COMPONENT_BOOL;
        out->of.boolean = j->b;
        ok = true;
        break;
    case WASMTIME_COMPONENT_VALTYPE_S8:
        if ((ok = json_int(j, true, INT8_MIN, INT8_MAX, &sv, &uv, "s8", e))) {
            out->kind = WASMTIME_COMPONENT_S8;
            out->of.s8 = (int8_t)sv;
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_S16:
        if ((ok = json_int(j, true, INT16_MIN, INT16_MAX, &sv, &uv, "s16", e))) {
            out->kind = WASMTIME_COMPONENT_S16;
            out->of.s16 = (int16_t)sv;
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_S32:
        if ((ok = json_int(j, true, INT32_MIN, INT32_MAX, &sv, &uv, "s32", e))) {
            out->kind = WASMTIME_COMPONENT_S32;
            out->of.s32 = (int32_t)sv;
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_S64:
        if ((ok = json_int(j, true, INT64_MIN, INT64_MAX, &sv, &uv, "s64", e))) {
            out->kind = WASMTIME_COMPONENT_S64;
            out->of.s64 = sv;
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_U8:
        if ((ok = json_int(j, false, 0, UINT8_MAX, &sv, &uv, "u8", e))) {
            out->kind = WASMTIME_COMPONENT_U8;
            out->of.u8 = (uint8_t)uv;
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_U16:
        if ((ok = json_int(j, false, 0, UINT16_MAX, &sv, &uv, "u16", e))) {
            out->kind = WASMTIME_COMPONENT_U16;
            out->of.u16 = (uint16_t)uv;
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_U32:
        if ((ok = json_int(j, false, 0, UINT32_MAX, &sv, &uv, "u32", e))) {
            out->kind = WASMTIME_COMPONENT_U32;
            out->of.u32 = (uint32_t)uv;
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_U64:
        if ((ok = json_int(j, false, 0, UINT64_MAX, &sv, &uv, "u64", e))) {
            out->kind = WASMTIME_COMPONENT_U64;
            out->of.u64 = uv;
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_F32:
    case WASMTIME_COMPONENT_VALTYPE_F64: {
        if (j->kind != J_NUM) {
            err_set(e, "expected a number, got %s", jkind_name(j));
            break;
        }
        bool parsed;
        double d = parse_double(j->s, j->slen, &parsed);
        if (!parsed) {
            err_set(e, "%s is not a representable number", j->s);
            break;
        }
        if (ty->kind == WASMTIME_COMPONENT_VALTYPE_F32) {
            out->kind = WASMTIME_COMPONENT_F32;
            out->of.f32 = (float)d;
        } else {
            out->kind = WASMTIME_COMPONENT_F64;
            out->of.f64 = d;
        }
        ok = true;
        break;
    }
    case WASMTIME_COMPONENT_VALTYPE_CHAR: {
        uint32_t cp;
        if (j->kind != J_STR || !decode_utf8_scalar(j->s, j->slen, &cp)) {
            err_set(e, "expected a one-character string");
            break;
        }
        out->kind = WASMTIME_COMPONENT_CHAR;
        out->of.character = cp;
        ok = true;
        break;
    }
    case WASMTIME_COMPONENT_VALTYPE_STRING:
        if (j->kind != J_STR) {
            err_set(e, "expected a string, got %s", jkind_name(j));
            break;
        }
        out->kind = WASMTIME_COMPONENT_STRING;
        make_name(&out->of.string, j->s, j->slen);
        ok = true;
        break;
    case WASMTIME_COMPONENT_VALTYPE_LIST: ok = build_list(out, j, ty, hint, e); break;
    case WASMTIME_COMPONENT_VALTYPE_RECORD: ok = build_record(out, j, ty, hint, e); break;
    case WASMTIME_COMPONENT_VALTYPE_TUPLE: {
        size_t n = p_wasmtime_component_tuple_type_types_count(ty->of.tuple);
        if (j->kind != J_ARR || j->count != n) {
            err_set(e, "expected an array of %zu elements for a tuple", n);
            break;
        }
        const JNode* th = hint_part(hint, "tuple");
        out->kind = WASMTIME_COMPONENT_TUPLE;
        p_wasmtime_component_valtuple_new_uninit(&out->of.tuple, n);
        for (size_t i = 0; i < n; i++) {
            out->of.tuple.data[i].kind = WASMTIME_COMPONENT_BOOL;
            out->of.tuple.data[i].of.boolean = false;
        }
        ok = true;
        for (size_t i = 0; ok && i < n; i++) {
            wasmtime_component_valtype_t et;
            p_wasmtime_component_tuple_type_types_nth(ty->of.tuple, i, &et);
            const JNode* eh = (th != NULL && th->kind == J_ARR && i < th->count) ? &th->items[i] : NULL;
            ok = build_val(&out->of.tuple.data[i], &j->items[i], &et, eh, e);
            p_wasmtime_component_valtype_delete(&et);
        }
        break;
    }
    case WASMTIME_COMPONENT_VALTYPE_VARIANT: ok = build_variant(out, j, ty, hint, e); break;
    case WASMTIME_COMPONENT_VALTYPE_ENUM: {
        if (j->kind != J_STR) {
            err_set(e, "expected a string for an enum, got %s", jkind_name(j));
            break;
        }
        size_t n = p_wasmtime_component_enum_type_names_count(ty->of.enum_);
        for (size_t i = 0; i < n; i++) {
            const char* name;
            size_t nlen;
            p_wasmtime_component_enum_type_names_nth(ty->of.enum_, i, &name, &nlen);
            if (name_eq_lyric(name, nlen, true, j->s, j->slen)) {
                out->kind = WASMTIME_COMPONENT_ENUM;
                make_name(&out->of.enumeration, name, nlen);
                ok = true;
                break;
            }
        }
        if (!ok) err_set(e, "unknown enum case \"%s\"", j->s);
        break;
    }
    case WASMTIME_COMPONENT_VALTYPE_OPTION:
        if (j->kind == J_NULL) {
            out->kind = WASMTIME_COMPONENT_OPTION;
            out->of.option = NULL;
            ok = true;
        } else {
            wasmtime_component_valtype_t it;
            p_wasmtime_component_option_type_ty(ty->of.option, &it);
            wasmtime_component_val_t* boxed = NULL;
            ok = build_boxed(&boxed, j, &it, hint_part(hint, "option"), e);
            p_wasmtime_component_valtype_delete(&it);
            if (ok) {
                out->kind = WASMTIME_COMPONENT_OPTION;
                out->of.option = boxed;
            }
        }
        break;
    case WASMTIME_COMPONENT_VALTYPE_RESULT: {
        const JNode* okv = jget(j, "ok");
        const JNode* errv = jget(j, "err");
        if (j->kind != J_OBJ || (okv == NULL) == (errv == NULL)) {
            err_set(e, "expected {\"ok\": ...} or {\"err\": ...}");
            break;
        }
        bool is_ok = okv != NULL;
        wasmtime_component_valtype_t pt;
        bool has = is_ok ? p_wasmtime_component_result_type_ok(ty->of.result, &pt)
                         : p_wasmtime_component_result_type_err(ty->of.result, &pt);
        wasmtime_component_val_t* boxed = NULL;
        ok = true;
        if (has) {
            ok = build_boxed(&boxed, is_ok ? okv : errv, &pt, hint_part(hint_part(hint, "result"), is_ok ? "ok" : "err"), e);
            p_wasmtime_component_valtype_delete(&pt);
        }
        if (ok) {
            out->kind = WASMTIME_COMPONENT_RESULT;
            out->of.result.is_ok = is_ok;
            out->of.result.val = boxed;
        }
        break;
    }
    case WASMTIME_COMPONENT_VALTYPE_FLAGS: {
        if (j->kind != J_ARR) {
            err_set(e, "expected an array of flag names, got %s", jkind_name(j));
            break;
        }
        size_t n = p_wasmtime_component_flags_type_names_count(ty->of.flags);
        out->kind = WASMTIME_COMPONENT_FLAGS;
        p_wasmtime_component_valflags_new_uninit(&out->of.flags, j->count);
        for (size_t k = 0; k < j->count; k++) p_wasm_byte_vec_new_empty(&out->of.flags.data[k]);
        ok = true;
        for (size_t k = 0; ok && k < j->count; k++) {
            const JNode* f = &j->items[k];
            bool found = false;
            for (size_t i = 0; f->kind == J_STR && i < n; i++) {
                const char* name;
                size_t nlen;
                p_wasmtime_component_flags_type_names_nth(ty->of.flags, i, &name, &nlen);
                if (name_eq_lyric(name, nlen, false, f->s, f->slen)) {
                    p_wasm_byte_vec_delete(&out->of.flags.data[k]);
                    make_name(&out->of.flags.data[k], name, nlen);
                    found = true;
                    break;
                }
            }
            if (!found) {
                err_set(e, "unknown flag");
                ok = false;
            }
        }
        break;
    }
    case WASMTIME_COMPONENT_VALTYPE_MAP: {
        wasmtime_component_valtype_t kt, vt;
        p_wasmtime_component_map_type_key(ty->of.map, &kt);
        p_wasmtime_component_map_type_value(ty->of.map, &vt);
        const JNode* vh = hint_part(hint, "map");
        if (j->kind == J_OBJ && kt.kind == WASMTIME_COMPONENT_VALTYPE_STRING) {
            out->kind = WASMTIME_COMPONENT_MAP;
            p_wasmtime_component_valmap_new_uninit(&out->of.map, j->count);
            for (size_t i = 0; i < j->count; i++) {
                out->of.map.data[i].key.kind = WASMTIME_COMPONENT_STRING;
                make_name(&out->of.map.data[i].key.of.string, j->keys[i], j->klens[i]);
                out->of.map.data[i].value.kind = WASMTIME_COMPONENT_BOOL;
                out->of.map.data[i].value.of.boolean = false;
            }
            ok = true;
            for (size_t i = 0; ok && i < j->count; i++) ok = build_val(&out->of.map.data[i].value, &j->items[i], &vt, vh, e);
        } else if (j->kind == J_ARR) {
            out->kind = WASMTIME_COMPONENT_MAP;
            p_wasmtime_component_valmap_new_uninit(&out->of.map, j->count);
            for (size_t i = 0; i < j->count; i++) {
                out->of.map.data[i].key.kind = WASMTIME_COMPONENT_BOOL;
                out->of.map.data[i].key.of.boolean = false;
                out->of.map.data[i].value.kind = WASMTIME_COMPONENT_BOOL;
                out->of.map.data[i].value.of.boolean = false;
            }
            ok = true;
            for (size_t i = 0; ok && i < j->count; i++) {
                const JNode* pair = &j->items[i];
                if (pair->kind != J_ARR || pair->count != 2) {
                    err_set(e, "expected [key, value] pairs for a map");
                    ok = false;
                    break;
                }
                ok = build_val(&out->of.map.data[i].key, &pair->items[0], &kt, NULL, e) &&
                     build_val(&out->of.map.data[i].value, &pair->items[1], &vt, vh, e);
            }
        } else {
            err_set(e, "expected an object or an array of pairs for a map, got %s", jkind_name(j));
        }
        p_wasmtime_component_valtype_delete(&kt);
        p_wasmtime_component_valtype_delete(&vt);
        break;
    }
    default: err_set(e, "this component type (kind %d) cannot cross the plugin boundary", (int)ty->kind); break;
    }
    if (!ok) val_reset(out);
    return ok;
}

/* ── Components ─────────────────────────────────────────────────────────── */

typedef struct {
    char* instance; /* "" for a root-level import */
    char* func;
    char* key; /* "<instance>#<func>" */
} ImportDesc;

typedef struct {
    char* name;
    wasmtime_component_export_index_t* index; /* NULL when several instances export the name */
} ExportEntry;

typedef struct {
    wasmtime_component_t* component;
    wasmtime_component_linker_t* linker;
    ImportDesc* imports;
    size_t nimports;
    ExportEntry* exports;
    size_t nexports;
    JNode hints; /* J_NULL until loaded */
    bool hints_loaded;
    int instances;
} Component;

struct Instance;

typedef struct Instance {
    Component* comp;
    wasmtime_store_t* store;
    wasmtime_context_t* ctx;
    wasmtime_component_instance_t inst;
    lyric_wasmhost_import_fn import_fn;
    void* userdata;
    uint64_t deadline_ns;
    bool timed_out;
    bool busy;
    bool dead;
    char host_error[512];
} Instance;

/* Handles: ids index a growing table and are never reused. */
static pthread_mutex_t g_handles_mu = PTHREAD_MUTEX_INITIALIZER;
static void** g_handles;
static uint8_t* g_handle_kinds; /* 1 component, 2 instance, 0 released */
static size_t g_nhandles, g_handles_cap;

static int64_t handle_add(void* p, uint8_t kind) {
    pthread_mutex_lock(&g_handles_mu);
    if (g_nhandles == g_handles_cap) {
        size_t cap = g_handles_cap ? g_handles_cap * 2 : 16;
        void** h = (void**)realloc(g_handles, cap * sizeof(void*));
        uint8_t* k = h ? (uint8_t*)realloc(g_handle_kinds, cap) : NULL;
        if (h) g_handles = h;
        if (k) g_handle_kinds = k;
        if (h == NULL || k == NULL) {
            pthread_mutex_unlock(&g_handles_mu);
            return 0;
        }
        g_handles_cap = cap;
    }
    g_handles[g_nhandles] = p;
    g_handle_kinds[g_nhandles] = kind;
    int64_t id = (int64_t)++g_nhandles;
    pthread_mutex_unlock(&g_handles_mu);
    return id;
}

static void* handle_get(int64_t id, uint8_t kind) {
    void* p = NULL;
    pthread_mutex_lock(&g_handles_mu);
    if (id > 0 && (size_t)id <= g_nhandles && g_handle_kinds[id - 1] == kind) p = g_handles[id - 1];
    pthread_mutex_unlock(&g_handles_mu);
    return p;
}

static void* handle_take(int64_t id, uint8_t kind) {
    void* p = NULL;
    pthread_mutex_lock(&g_handles_mu);
    if (id > 0 && (size_t)id <= g_nhandles && g_handle_kinds[id - 1] == kind) {
        p = g_handles[id - 1];
        g_handles[id - 1] = NULL;
        g_handle_kinds[id - 1] = 0;
    }
    pthread_mutex_unlock(&g_handles_mu);
    return p;
}

static char* dup_n(const char* s, size_t n) {
    char* r = (char*)malloc(n + 1);
    if (r) {
        memcpy(r, s, n);
        r[n] = '\0';
    }
    return r;
}

static void component_free(Component* c) {
    if (c == NULL) return;
    if (c->linker) p_wasmtime_component_linker_delete(c->linker);
    for (size_t i = 0; i < c->nimports; i++) {
        free(c->imports[i].instance);
        free(c->imports[i].func);
        free(c->imports[i].key);
    }
    free(c->imports);
    for (size_t i = 0; i < c->nexports; i++) {
        free(c->exports[i].name);
        if (c->exports[i].index) p_wasmtime_component_export_index_delete(c->exports[i].index);
    }
    free(c->exports);
    jfree(&c->hints);
    if (c->component) p_wasmtime_component_delete(c->component);
    free(c);
}

static wasmtime_error_t* import_callback(void* env, wasmtime_context_t* ctx, const wasmtime_component_func_type_t* ty,
                                         wasmtime_component_val_t* args, size_t nargs, wasmtime_component_val_t* results,
                                         size_t nresults);

static bool add_import(Component* c, wasmtime_component_linker_instance_t* li, const char* inst, size_t ilen,
                       const char* func, size_t flen) {
    ImportDesc* grown = (ImportDesc*)realloc(c->imports, (c->nimports + 1) * sizeof(ImportDesc));
    if (grown == NULL) {
        set_error("out of memory");
        return false;
    }
    c->imports = grown;
    ImportDesc* d = &c->imports[c->nimports];
    d->instance = dup_n(inst, ilen);
    d->func = dup_n(func, flen);
    d->key = (char*)malloc(ilen + flen + 2);
    if (d->instance == NULL || d->func == NULL || d->key == NULL) {
        free(d->instance);
        free(d->func);
        free(d->key);
        set_error("out of memory");
        return false;
    }
    snprintf(d->key, ilen + flen + 2, "%s#%s", d->instance, d->func);
    c->nimports++;
    /* The descriptors array may move as it grows, so the callback receives
     * the component and the import's index, packed into a small cell. */
    wasmtime_error_t* err =
        p_wasmtime_component_linker_instance_add_func(li, func, flen, import_callback, (void*)(uintptr_t)c->nimports, NULL);
    if (err != NULL) {
        char msg[512];
        take_error_message(err, msg, sizeof(msg));
        set_error("cannot define import %.*s#%.*s: %s", (int)ilen, inst, (int)flen, func, msg);
        return false;
    }
    return true;
}

static bool define_instance_imports(Component* c, wasmtime_component_linker_instance_t* root, const char* name,
                                    size_t nlen, const wasmtime_component_instance_type_t* ity) {
    wasmtime_component_linker_instance_t* li = NULL;
    wasmtime_error_t* err = p_wasmtime_component_linker_instance_add_instance(root, name, nlen, &li);
    if (err != NULL) {
        char msg[512];
        take_error_message(err, msg, sizeof(msg));
        set_error("cannot define import instance %.*s: %s", (int)nlen, name, msg);
        return false;
    }
    bool ok = true;
    size_t n = p_wasmtime_component_instance_type_export_count(ity, g_engine);
    for (size_t i = 0; ok && i < n; i++) {
        const char* fname;
        size_t flen;
        wasmtime_component_extern_t* ext = NULL;
        if (!p_wasmtime_component_instance_type_export_nth(ity, g_engine, i, &fname, &flen, &ext)) continue;
        wasmtime_component_item_t item;
        p_wasmtime_component_extern_type(ext, &item);
        if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC) {
            ok = add_import(c, li, name, nlen, fname, flen);
        } else if (item.kind != WASMTIME_COMPONENT_ITEM_TYPE) {
            set_error("import %.*s#%.*s is not a function or a value type; a plugin imports functions only", (int)nlen,
                      name, (int)flen, fname);
            ok = false;
        }
        p_wasmtime_component_item_delete(&item);
        p_wasmtime_component_extern_delete(ext);
    }
    p_wasmtime_component_linker_instance_delete(li);
    return ok;
}

static bool export_add(Component* c, const char* name, size_t nlen, wasmtime_component_export_index_t* idx) {
    for (size_t i = 0; i < c->nexports; i++) {
        if (strlen(c->exports[i].name) == nlen && memcmp(c->exports[i].name, name, nlen) == 0) {
            /* Exported by more than one instance: ambiguous. */
            if (c->exports[i].index) p_wasmtime_component_export_index_delete(c->exports[i].index);
            c->exports[i].index = NULL;
            p_wasmtime_component_export_index_delete(idx);
            return true;
        }
    }
    ExportEntry* grown = (ExportEntry*)realloc(c->exports, (c->nexports + 1) * sizeof(ExportEntry));
    if (grown == NULL) return false;
    c->exports = grown;
    c->exports[c->nexports].name = dup_n(name, nlen);
    c->exports[c->nexports].index = idx;
    if (c->exports[c->nexports].name == NULL) return false;
    c->nexports++;
    return true;
}

static bool collect_exports(Component* c, const wasmtime_component_type_t* cty) {
    size_t n = p_wasmtime_component_type_export_count(cty, g_engine);
    for (size_t i = 0; i < n; i++) {
        const char* name;
        size_t nlen;
        wasmtime_component_extern_t* ext = NULL;
        if (!p_wasmtime_component_type_export_nth(cty, g_engine, i, &name, &nlen, &ext)) continue;
        wasmtime_component_item_t item;
        p_wasmtime_component_extern_type(ext, &item);
        bool ok = true;
        if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC) {
            wasmtime_component_export_index_t* idx = p_wasmtime_component_get_export_index(c->component, NULL, name, nlen);
            if (idx != NULL) ok = export_add(c, name, nlen, idx);
        } else if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE) {
            wasmtime_component_export_index_t* iidx = p_wasmtime_component_get_export_index(c->component, NULL, name, nlen);
            size_t m = p_wasmtime_component_instance_type_export_count(item.of.component_instance, g_engine);
            for (size_t k = 0; ok && iidx != NULL && k < m; k++) {
                const char* fname;
                size_t flen;
                wasmtime_component_extern_t* fext = NULL;
                if (!p_wasmtime_component_instance_type_export_nth(item.of.component_instance, g_engine, k, &fname, &flen,
                                                                   &fext))
                    continue;
                wasmtime_component_item_t fitem;
                p_wasmtime_component_extern_type(fext, &fitem);
                if (fitem.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC) {
                    wasmtime_component_export_index_t* fidx =
                        p_wasmtime_component_get_export_index(c->component, iidx, fname, flen);
                    if (fidx != NULL) ok = export_add(c, fname, flen, fidx);
                }
                p_wasmtime_component_item_delete(&fitem);
                p_wasmtime_component_extern_delete(fext);
            }
            if (iidx != NULL) p_wasmtime_component_export_index_delete(iidx);
        }
        p_wasmtime_component_item_delete(&item);
        p_wasmtime_component_extern_delete(ext);
        if (!ok) {
            set_error("out of memory");
            return false;
        }
    }
    return true;
}

static bool build_linker(Component* c, const wasmtime_component_type_t* cty) {
    c->linker = p_wasmtime_component_linker_new(g_engine);
    if (c->linker == NULL) {
        set_error("wasmtime could not create a component linker");
        return false;
    }
    wasmtime_error_t* err = p_wasmtime_component_linker_add_wasip2(c->linker);
    if (err != NULL) {
        char msg[512];
        take_error_message(err, msg, sizeof(msg));
        set_error("cannot add WASI p2 to the linker: %s", msg);
        return false;
    }
    wasmtime_component_linker_instance_t* root = p_wasmtime_component_linker_root(c->linker);
    bool ok = true;
    size_t n = p_wasmtime_component_type_import_count(cty, g_engine);
    for (size_t i = 0; ok && i < n; i++) {
        const char* name;
        size_t nlen;
        wasmtime_component_extern_t* ext = NULL;
        if (!p_wasmtime_component_type_import_nth(cty, g_engine, i, &name, &nlen, &ext)) continue;
        wasmtime_component_item_t item;
        p_wasmtime_component_extern_type(ext, &item);
        bool is_wasi = nlen >= 5 && memcmp(name, "wasi:", 5) == 0;
        if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE) {
            if (!is_wasi) ok = define_instance_imports(c, root, name, nlen, item.of.component_instance);
        } else if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC) {
            ok = add_import(c, root, "", 0, name, nlen);
        } else if (item.kind != WASMTIME_COMPONENT_ITEM_TYPE) {
            set_error("import %.*s is not a function, an instance of functions or a value type", (int)nlen, name);
            ok = false;
        }
        p_wasmtime_component_item_delete(&item);
        p_wasmtime_component_extern_delete(ext);
    }
    p_wasmtime_component_linker_instance_delete(root);
    return ok;
}

static bool read_file(const char* path, uint8_t** out, size_t* len) {
    FILE* f = fopen(path, "rb");
    if (f == NULL) {
        set_error("cannot open component '%s': %s", path, strerror(errno));
        return false;
    }
    uint8_t* buf = NULL;
    size_t n = 0, cap = 0;
    for (;;) {
        if (n == cap) {
            cap = cap ? cap * 2 : 65536;
            uint8_t* b = (uint8_t*)realloc(buf, cap);
            if (b == NULL) {
                free(buf);
                fclose(f);
                set_error("out of memory reading '%s'", path);
                return false;
            }
            buf = b;
        }
        size_t r = fread(buf + n, 1, cap - n, f);
        n += r;
        if (r == 0) break;
    }
    bool bad = ferror(f) != 0;
    fclose(f);
    if (bad) {
        free(buf);
        set_error("cannot read component '%s'", path);
        return false;
    }
    *out = buf;
    *len = n;
    return true;
}

LYRIC_WASMHOST_API int64_t lyric_wasmhost_load(const char* path) {
    if (!ensure_loaded()) return 0;
    uint8_t* bytes;
    size_t len;
    if (!read_file(path, &bytes, &len)) return 0;
    Component* c = (Component*)calloc(1, sizeof(Component));
    if (c == NULL) {
        free(bytes);
        set_error("out of memory");
        return 0;
    }
    wasmtime_error_t* err = p_wasmtime_component_new(g_engine, bytes, len, &c->component);
    free(bytes);
    if (err != NULL) {
        char msg[512];
        take_error_message(err, msg, sizeof(msg));
        set_error("'%s' is not a valid component: %s", path, msg);
        free(c);
        return 0;
    }
    wasmtime_component_type_t* cty = p_wasmtime_component_type(c->component);
    bool ok = build_linker(c, cty) && collect_exports(c, cty);
    p_wasmtime_component_type_delete(cty);
    if (!ok) {
        component_free(c);
        return 0;
    }
    int64_t id = handle_add(c, 1);
    if (id == 0) {
        component_free(c);
        set_error("out of memory");
    }
    return id;
}

LYRIC_WASMHOST_API void lyric_wasmhost_unload(int64_t id) {
    Component* c = (Component*)handle_take(id, 1);
    component_free(c);
}

/* ── Instances ──────────────────────────────────────────────────────────── */

static wasmtime_error_t* epoch_callback(wasmtime_context_t* ctx, void* data, uint64_t* delta,
                                        wasmtime_update_deadline_kind_t* kind) {
    (void)ctx;
    Instance* in = (Instance*)data;
    *kind = WASMTIME_UPDATE_DEADLINE_CONTINUE;
    if (in->deadline_ns != 0 && now_ns() >= in->deadline_ns) {
        in->timed_out = true;
        return p_wasmtime_error_new("the plugin call ran past its deadline");
    }
    *delta = 1;
    return NULL;
}

static void arm_deadline(Instance* in, int32_t timeout_ms) {
    in->timed_out = false;
    in->host_error[0] = '\0';
    in->deadline_ns = now_ns() + (uint64_t)(timeout_ms > 0 ? timeout_ms : 1) * 1000000ull;
    p_wasmtime_context_set_epoch_deadline(in->ctx, 1);
}

static void instance_free(Instance* in) {
    if (in == NULL) return;
    if (in->store) p_wasmtime_store_delete(in->store);
    if (in->comp) in->comp->instances--;
    free(in);
}

static char* call_export(Instance* in, const char* name, const char* params_json, int32_t timeout_ms);

LYRIC_WASMHOST_API int64_t lyric_wasmhost_instantiate(int64_t component, int64_t max_memory_bytes, int32_t timeout_ms,
                                                      lyric_wasmhost_import_fn import_fn, void* userdata) {
    if (!ensure_loaded()) return LYRIC_WASMHOST_ERROR;
    Component* c = (Component*)handle_get(component, 1);
    if (c == NULL) {
        set_error("unknown component id %lld", (long long)component);
        return LYRIC_WASMHOST_ERROR;
    }
    Instance* in = (Instance*)calloc(1, sizeof(Instance));
    if (in == NULL) {
        set_error("out of memory");
        return LYRIC_WASMHOST_ERROR;
    }
    in->comp = c;
    c->instances++;
    in->import_fn = import_fn;
    in->userdata = userdata;
    in->store = p_wasmtime_store_new(g_engine, in, NULL);
    if (in->store == NULL) {
        instance_free(in);
        set_error("wasmtime could not create a store");
        return LYRIC_WASMHOST_ERROR;
    }
    in->ctx = p_wasmtime_store_context(in->store);
    p_wasmtime_store_limiter(in->store, max_memory_bytes > 0 ? max_memory_bytes : -1, -1, -1, -1, -1);
    p_wasmtime_store_epoch_deadline_callback(in->store, epoch_callback, in, NULL);
    wasi_config_t* wasi = p_wasi_config_new();
    if (wasi == NULL) {
        instance_free(in);
        set_error("wasmtime could not create a WASI configuration");
        return LYRIC_WASMHOST_ERROR;
    }
    /* No directories, environment, arguments or network: only stderr. */
    p_wasi_config_inherit_stderr(wasi);
    wasmtime_error_t* err = p_wasmtime_context_set_wasi(in->ctx, wasi);
    if (err != NULL) {
        char msg[512];
        take_error_message(err, msg, sizeof(msg));
        instance_free(in);
        set_error("cannot configure WASI: %s", msg);
        return LYRIC_WASMHOST_ERROR;
    }
    if (!running_begin()) {
        instance_free(in);
        return LYRIC_WASMHOST_ERROR;
    }
    arm_deadline(in, timeout_ms);
    in->busy = true;
    err = p_wasmtime_component_linker_instantiate(c->linker, in->ctx, c->component, &in->inst);
    in->busy = false;
    running_end();
    if (err != NULL) {
        /* A trap leaves a wasm backtrace; a link error (an import the linker
         * cannot satisfy) has none. */
        wasm_frame_vec_t frames;
        p_wasmtime_error_wasm_trace(err, &frames);
        bool trapped = frames.size > 0 || in->host_error[0] != '\0';
        p_wasm_frame_vec_delete(&frames);
        char msg[512];
        take_error_message(err, msg, sizeof(msg));
        int64_t code = in->timed_out ? LYRIC_WASMHOST_TIMEOUT : (trapped ? LYRIC_WASMHOST_TRAP : LYRIC_WASMHOST_ERROR);
        if (in->timed_out) {
            set_error("starting the component took longer than %d ms", (int)timeout_ms);
        } else if (in->host_error[0] != '\0') {
            set_error("%s", in->host_error);
        } else {
            set_error("%s", msg);
        }
        instance_free(in);
        return code;
    }
    if (!c->hints_loaded) {
        c->hints_loaded = true;
        c->hints.kind = J_NULL;
        for (size_t i = 0; i < c->nexports; i++) {
            if (strcmp(c->exports[i].name, "plugin-type-hints") != 0) continue;
            char* env = call_export(in, "plugin-type-hints", "{}", timeout_ms);
            JNode parsed;
            char perr[256];
            bool good = env != NULL && jparse(env, &parsed, perr, sizeof(perr));
            const JNode* okv = good ? jget(&parsed, "ok") : NULL;
            JNode hints;
            bool hints_ok = okv != NULL && okv->kind == J_STR && jparse(okv->s, &hints, perr, sizeof(perr));
            if (good && okv == NULL) {
                /* The hints export itself failed: report it as a start failure. */
                const JNode* trap = jget(&parsed, "trap");
                const JNode* timeout = jget(&parsed, "timeout");
                set_error("plugin-type-hints failed: %s", env);
                jfree(&parsed);
                lyric_wasmhost_free(env);
                c->hints_loaded = false;
                int64_t code = timeout ? LYRIC_WASMHOST_TIMEOUT : (trap ? LYRIC_WASMHOST_TRAP : LYRIC_WASMHOST_ERROR);
                instance_free(in);
                return code;
            }
            if (hints_ok) {
                c->hints = hints;
            } else if (okv != NULL) {
                set_error("plugin-type-hints returned malformed hints: %s", perr);
                jfree(&parsed);
                lyric_wasmhost_free(env);
                c->hints_loaded = false;
                instance_free(in);
                return LYRIC_WASMHOST_ERROR;
            }
            if (good) jfree(&parsed);
            lyric_wasmhost_free(env);
            break;
        }
    }
    int64_t id = handle_add(in, 2);
    if (id == 0) {
        instance_free(in);
        set_error("out of memory");
        return LYRIC_WASMHOST_ERROR;
    }
    return id;
}

LYRIC_WASMHOST_API void* lyric_wasmhost_close(int64_t id) {
    Instance* in = (Instance*)handle_take(id, 2);
    if (in == NULL) return NULL;
    void* ud = in->userdata;
    instance_free(in);
    return ud;
}

static const ExportEntry* find_export(const Component* c, const char* name) {
    for (size_t i = 0; i < c->nexports; i++) {
        if (strcmp(c->exports[i].name, name) == 0) return &c->exports[i];
    }
    return NULL;
}

LYRIC_WASMHOST_API int32_t lyric_wasmhost_has_export(int64_t id, const char* name) {
    Instance* in = (Instance*)handle_get(id, 2);
    if (in == NULL) return 0;
    const ExportEntry* ex = find_export(in->comp, name);
    return (ex != NULL && ex->index != NULL) ? 1 : 0;
}

static const JNode* hints_for(const Component* c, const char* section, const char* key, const char* part) {
    const JNode* entry = jget(jget(&c->hints, section), key);
    return hint_part(entry, part);
}

static const JNode* hint_param(const JNode* params, size_t i) {
    if (params == NULL || params->kind != J_ARR || i >= params->count) return NULL;
    const JNode* h = &params->items[i];
    return h->kind == J_NULL ? NULL : h;
}

static char* finish_envelope(Sb* sb) {
    if (sb->oom) {
        free(sb->p);
        return envelope_message("invalid", "out of memory");
    }
    char* r = dup_cstr(sb->p);
    free(sb->p);
    return r;
}

static char* call_export(Instance* in, const char* name, const char* params_json, int32_t timeout_ms) {
    if (in->dead) return envelope_message("trap", "the instance trapped or timed out earlier and cannot be called");
    if (in->busy) return envelope_message("busy", "the plugin is already running a call (a re-entrant call)");
    const ExportEntry* ex = find_export(in->comp, name);
    if (ex == NULL) return envelope_message("missing", name);
    if (ex->index == NULL) {
        char msg[256];
        snprintf(msg, sizeof(msg), "export '%s' is exported by more than one instance", name);
        return envelope_message("invalid", msg);
    }
    wasmtime_component_func_t func;
    if (!p_wasmtime_component_instance_get_func(&in->inst, in->ctx, ex->index, &func)) return envelope_message("missing", name);
    JNode params;
    char perr[256];
    if (!jparse(params_json != NULL && params_json[0] != '\0' ? params_json : "null", &params, perr, sizeof(perr)))
        return envelope_message("invalid", perr);
    if (params.kind != J_OBJ && params.kind != J_NULL) {
        jfree(&params);
        return envelope_message("invalid", "call params must be an object keyed by parameter name");
    }
    wasmtime_component_func_type_t* fty = p_wasmtime_component_func_type(&func, in->ctx);
    size_t nparams = p_wasmtime_component_func_type_param_count(fty);
    const JNode* phints = hints_for(in->comp, "exports", name, "params");
    const JNode* rhint = hints_for(in->comp, "exports", name, "result");
    wasmtime_component_val_t* args =
        (wasmtime_component_val_t*)calloc(nparams ? nparams : 1, sizeof(wasmtime_component_val_t));
    char* result = NULL;
    Err e;
    e.msg[0] = '\0';
    bool ok = args != NULL;
    if (!ok) result = envelope_message("invalid", "out of memory");
    size_t built = 0;
    for (size_t i = 0; ok && i < nparams; i++) {
        const char* pname;
        size_t plen;
        wasmtime_component_valtype_t pt;
        p_wasmtime_component_func_type_param_nth(fty, i, &pname, &plen, &pt);
        args[i].kind = WASMTIME_COMPONENT_BOOL;
        args[i].of.boolean = false;
        built = i + 1;
        Sb key = {0};
        wit_to_lyric(pname, plen, false, &key);
        const JNode* m = key.oom ? NULL : jget_n(&params, key.p, key.n);
        if (m == NULL && pt.kind == WASMTIME_COMPONENT_VALTYPE_OPTION) {
            args[i].kind = WASMTIME_COMPONENT_OPTION;
            args[i].of.option = NULL;
        } else if (m == NULL) {
            char msg[300];
            snprintf(msg, sizeof(msg), "missing parameter '%s'", key.p ? key.p : "");
            result = envelope_message("invalid", msg);
            ok = false;
        } else if (!build_val(&args[i], m, &pt, hint_param(phints, i), &e)) {
            char msg[900];
            snprintf(msg, sizeof(msg), "parameter '%s': %s", key.p, e.msg);
            result = envelope_message("invalid", msg);
            ok = false;
        }
        free(key.p);
        p_wasmtime_component_valtype_delete(&pt);
    }
    wasmtime_component_valtype_t rty;
    bool has_result = p_wasmtime_component_func_type_result(fty, &rty);
    if (ok) {
        wasmtime_component_val_t res;
        res.kind = WASMTIME_COMPONENT_BOOL;
        res.of.boolean = false;
        if (!running_begin()) {
            result = envelope_message("invalid", g_last_error);
        } else {
            arm_deadline(in, timeout_ms);
            in->busy = true;
            wasmtime_error_t* err =
                p_wasmtime_component_func_call(&func, in->ctx, args, nparams, has_result ? &res : NULL, has_result ? 1 : 0);
            in->busy = false;
            running_end();
            if (err != NULL) {
                char msg[512];
                take_error_message(err, msg, sizeof(msg));
                in->dead = true;
                if (in->timed_out) {
                    Sb sb = {0};
                    sb_printf(&sb, "{\"timeout\":%d}", (int)timeout_ms);
                    result = finish_envelope(&sb);
                } else {
                    result = envelope_message("trap", in->host_error[0] != '\0' ? in->host_error : msg);
                }
            } else {
                Sb sb = {0};
                sb_puts(&sb, "{\"ok\":");
                bool emitted = true;
                if (has_result) {
                    emitted = emit_val(&sb, &res, &rty, rhint, &e);
                    p_wasmtime_component_val_delete(&res);
                } else {
                    sb_puts(&sb, "null");
                }
                sb_puts(&sb, "}");
                wasmtime_error_t* perr2 = p_wasmtime_component_func_post_return(&func, in->ctx);
                if (perr2 != NULL) {
                    char msg[512];
                    take_error_message(perr2, msg, sizeof(msg));
                    in->dead = true;
                    free(sb.p);
                    result = envelope_message("trap", msg);
                } else if (!emitted) {
                    free(sb.p);
                    char msg[600];
                    snprintf(msg, sizeof(msg), "the result of '%s' cannot be written as JSON: %s", name, e.msg);
                    result = envelope_message("invalid", msg);
                } else {
                    result = finish_envelope(&sb);
                }
            }
        }
    }
    if (has_result) p_wasmtime_component_valtype_delete(&rty);
    for (size_t i = 0; i < built; i++) p_wasmtime_component_val_delete(&args[i]);
    free(args);
    p_wasmtime_component_func_type_delete(fty);
    jfree(&params);
    return result;
}

LYRIC_WASMHOST_API char* lyric_wasmhost_call(int64_t id, const char* name, const char* params_json, int32_t timeout_ms) {
    if (!ensure_loaded()) return envelope_message("invalid", g_unavailable);
    Instance* in = (Instance*)handle_get(id, 2);
    if (in == NULL) return envelope_message("invalid", "unknown plugin instance");
    return call_export(in, name, params_json, timeout_ms);
}

/* ── Host imports ───────────────────────────────────────────────────────── */

static wasmtime_error_t* import_fail(Instance* in, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(in->host_error, sizeof(in->host_error), fmt, ap);
    va_end(ap);
    return p_wasmtime_error_new(in->host_error);
}

static wasmtime_error_t* import_callback(void* env, wasmtime_context_t* ctx, const wasmtime_component_func_type_t* ty,
                                         wasmtime_component_val_t* args, size_t nargs, wasmtime_component_val_t* results,
                                         size_t nresults) {
    Instance* in = (Instance*)p_wasmtime_context_get_data(ctx);
    size_t index = (size_t)(uintptr_t)env - 1;
    if (in == NULL || index >= in->comp->nimports) return p_wasmtime_error_new("host import without an instance");
    const ImportDesc* d = &in->comp->imports[index];
    if (in->import_fn == NULL) return import_fail(in, "the host serves no imports (%s)", d->key);
    const JNode* phints = hints_for(in->comp, "imports", d->key, "params");
    const JNode* rhint = hints_for(in->comp, "imports", d->key, "result");
    Sb sb = {0};
    Err e;
    e.msg[0] = '\0';
    sb_put(&sb, "{", 1);
    for (size_t i = 0; i < nargs; i++) {
        const char* pname;
        size_t plen;
        wasmtime_component_valtype_t pt;
        p_wasmtime_component_func_type_param_nth(ty, i, &pname, &plen, &pt);
        if (i > 0) sb_put(&sb, ",", 1);
        emit_name(&sb, pname, plen, false);
        sb_put(&sb, ":", 1);
        bool ok = emit_val(&sb, &args[i], &pt, hint_param(phints, i), &e);
        p_wasmtime_component_valtype_delete(&pt);
        if (!ok) {
            free(sb.p);
            return import_fail(in, "the arguments of %s cannot be written as JSON: %s", d->key, e.msg);
        }
    }
    sb_put(&sb, "}", 1);
    if (sb.oom) {
        free(sb.p);
        return import_fail(in, "out of memory");
    }
    /* The host may take a while (a capability that does I/O); the guest is
     * not running meanwhile, so the deadline only applies once it resumes. */
    char* answer = in->import_fn(in->userdata, d->instance, d->func, sb.p);
    free(sb.p);
    if (answer == NULL) return import_fail(in, "the host failed to answer %s", d->key);
    JNode parsed;
    char perr[256];
    bool good = jparse(answer, &parsed, perr, sizeof(perr));
    lyric_wasmhost_free(answer);
    if (!good) return import_fail(in, "the host's answer to %s is not JSON: %s", d->key, perr);
    wasmtime_error_t* out = NULL;
    wasmtime_component_valtype_t rty;
    if (nresults > 0 && p_wasmtime_component_func_type_result(ty, &rty)) {
        results[0].kind = WASMTIME_COMPONENT_BOOL;
        results[0].of.boolean = false;
        if (!build_val(&results[0], &parsed, &rty, rhint, &e))
            out = import_fail(in, "the host's answer to %s does not fit its result type: %s", d->key, e.msg);
        p_wasmtime_component_valtype_delete(&rty);
    }
    jfree(&parsed);
    return out;
}
