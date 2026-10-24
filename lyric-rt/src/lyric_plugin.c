/* lyric_plugin.c — loading trusted in-process plugins (docs/69 §10, D230).
 *
 * Std.PluginTrustedHost's native kernel opens a plugin shared library built
 * with `--shape plugin`, checks its `lyric_plugin_abi_v1` fingerprint and
 * calls its `lyric_plugin_entry_v1` for a PluginServer.  The library carries
 * no copy of this runtime: its lyric_rt references bind to the host
 * executable's exported runtime when it is opened, so the process keeps one
 * heap, one reference-counting discipline and one scheduler.
 *
 * Libraries are never closed.  A Lyric object the plugin allocated carries a
 * destructor that is plugin code, and such objects outlive any call into the
 * plugin (a returned JsonValue, a cached server), so unloading the library
 * would leave the host calling unmapped code (docs/69 Q-PLG-009).
 *
 * Windows and wasm32 have no trusted native plugins: a Windows DLL cannot
 * import the runtime from the executable that loads it without an import
 * library built for that executable, and WASI has no dynamic loading.  There
 * lyric_plugin_dl_open reports that and returns NULL.
 */
#if defined(__linux__)
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#endif

#include "lyric_rt.h"

#include <stdint.h>
#include <string.h>

#if !defined(_WIN32) && !defined(__wasi__)
#include <dlfcn.h>
#endif

static _Thread_local char g_plugin_err[1024];

static void plugin_set_error(const char* message) {
    size_t n = strlen(message);
    if (n >= sizeof(g_plugin_err)) {
        n = sizeof(g_plugin_err) - 1;
    }
    memcpy(g_plugin_err, message, n);
    g_plugin_err[n] = '\0';
}

LyricString* lyric_plugin_text(const char* text) {
    if (text == NULL) {
        return lyric_string_from_literal((const uint8_t*)"", 0);
    }
    return lyric_string_from_literal((const uint8_t*)text, (int64_t)strlen(text));
}

LyricString* lyric_plugin_dl_error(void) {
    return lyric_plugin_text(g_plugin_err);
}

#if defined(_WIN32) || defined(__wasi__)

void* lyric_plugin_dl_open(const char* path) {
    (void)path;
#if defined(_WIN32)
    plugin_set_error("trusted native plugins are not supported on Windows");
#else
    plugin_set_error("trusted native plugins are not supported on wasm32");
#endif
    return NULL;
}

void* lyric_plugin_dl_sym(void* handle, const char* name) {
    (void)handle;
    (void)name;
    return NULL;
}

#else

void* lyric_plugin_dl_open(const char* path) {
    void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char* why = dlerror();
        plugin_set_error(why != NULL ? why : "dlopen failed");
    }
    return handle;
}

void* lyric_plugin_dl_sym(void* handle, const char* name) {
    if (handle == NULL) {
        return NULL;
    }
    (void)dlerror();
    return dlsym(handle, name);
}

#endif

typedef const char* (*LyricPluginTextFn)(void);
typedef void* (*LyricPluginEntryFn)(void);

LyricString* lyric_plugin_call_text(void* fn) {
    if (fn == NULL) {
        return lyric_plugin_text(NULL);
    }
    LyricPluginTextFn f;
    memcpy(&f, &fn, sizeof f);
    return lyric_plugin_text(f());
}

void* lyric_plugin_call_entry(void* fn) {
    if (fn == NULL) {
        return NULL;
    }
    LyricPluginEntryFn f;
    memcpy(&f, &fn, sizeof f);
    return f();
}
