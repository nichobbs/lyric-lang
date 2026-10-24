/* lyric_wasmhost_unsupported.c — the in-process wasm embedding where the
 * runtime cannot load wasmtime: wasm32-wasi (no dlopen, and a plugin host is
 * not itself a wasm guest) and x86_64-pc-windows-msvc (the shim's loader and
 * ticker are POSIX; #8540 ports them to LoadLibrary and Win32 threads).
 *
 * Every symbol of lyric_wasmhost.h resolves, so Std.Plugin links unchanged;
 * `lyric_wasmhost_available` answers 0 and Std.Plugin skips component
 * payloads, as it does on a host without libwasmtime.
 */
#include "lyric_wasmhost.h"

#include <stdlib.h>
#include <string.h>

#if defined(__wasi__)
#define LWH_UNSUPPORTED_REASON "in-process wasm is not available on wasm32-wasi"
#else
#define LWH_UNSUPPORTED_REASON "in-process wasm is not yet available on this operating system"
#endif

LYRIC_WASMHOST_API char* lyric_wasmhost_alloc(int64_t size) { return (char*)malloc(size > 0 ? (size_t)size : 1); }

LYRIC_WASMHOST_API void lyric_wasmhost_free(char* p) { free(p); }

static char* dup_reason(const char* s) {
    size_t n = strlen(s);
    char* r = lyric_wasmhost_alloc((int64_t)n + 1);
    if (r) memcpy(r, s, n + 1);
    return r;
}

LYRIC_WASMHOST_API int32_t lyric_wasmhost_available(void) { return 0; }

LYRIC_WASMHOST_API char* lyric_wasmhost_unavailable_reason(void) { return dup_reason(LWH_UNSUPPORTED_REASON); }

LYRIC_WASMHOST_API char* lyric_wasmhost_last_error(void) { return dup_reason(LWH_UNSUPPORTED_REASON); }

LYRIC_WASMHOST_API int64_t lyric_wasmhost_load(const char* path) {
    (void)path;
    return 0;
}

LYRIC_WASMHOST_API void lyric_wasmhost_unload(int64_t component) { (void)component; }

LYRIC_WASMHOST_API int64_t lyric_wasmhost_instantiate(int64_t component, int64_t max_memory_bytes, int32_t timeout_ms,
                                                      lyric_wasmhost_import_fn import_fn, void* userdata) {
    (void)component;
    (void)max_memory_bytes;
    (void)timeout_ms;
    (void)import_fn;
    (void)userdata;
    return LYRIC_WASMHOST_ERROR;
}

LYRIC_WASMHOST_API char* lyric_wasmhost_call(int64_t instance, const char* name, const char* params_json,
                                             int32_t timeout_ms) {
    (void)instance;
    (void)name;
    (void)params_json;
    (void)timeout_ms;
    return dup_reason("{\"invalid\":\"" LWH_UNSUPPORTED_REASON "\"}");
}

LYRIC_WASMHOST_API int32_t lyric_wasmhost_has_export(int64_t instance, const char* name) {
    (void)instance;
    (void)name;
    return 0;
}

LYRIC_WASMHOST_API void* lyric_wasmhost_close(int64_t instance) {
    (void)instance;
    return NULL;
}
