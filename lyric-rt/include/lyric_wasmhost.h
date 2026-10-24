/* lyric_wasmhost.h — the in-process wasmtime embedding behind Std.Plugin's
 * component mode (docs/69 §9.3).
 *
 * The shim hosts WIT-typed plugin components with the wasmtime C API.  It
 * never links libwasmtime: the library is loaded at run time (dlopen) from
 * $LYRIC_WASMTIME_LIB, next to the shim (or the native executable that links
 * it statically), or from the loader path, so `lyric_wasmhost_available`
 * answers whether the embedding can be used on this machine.
 *
 * Every value crosses as JSON text in D207's encoding; the shim converts
 * between JSON and component values generically, driven by the function
 * types wasmtime reports and by the component's optional type hints
 * (`plugin-type-hints`).  Handles are positive 64-bit ids.  Strings returned
 * by the shim are allocated with `lyric_wasmhost_alloc` and released with
 * `lyric_wasmhost_free`; so is the string a host-import callback returns.
 *
 * Builds: part of lyric_rt.a (native hosts), and liblyric_wasmhost.so /
 * .dylib on its own for dotnet and JVM hosts (`make -C lyric-rt wasmhost`).
 */
#ifndef LYRIC_WASMHOST_H
#define LYRIC_WASMHOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define LYRIC_WASMHOST_API __declspec(dllexport)
#else
#define LYRIC_WASMHOST_API __attribute__((visibility("default")))
#endif

/* A host import: called on the thread that called into the component, with
 * the import's instance name (`lyric:notes/editor-api-workspace-read`), its
 * function name and its arguments as a JSON object keyed by the Lyric
 * parameter names.  Returns the JSON of the import's result value (for a
 * capability, `{"ok": ...}` or `{"err": {"case": ..., ...}}`) in a buffer
 * from `lyric_wasmhost_alloc`, which the shim releases; NULL traps the
 * component. */
typedef char* (*lyric_wasmhost_import_fn)(void* userdata, const char* instance, const char* func,
                                          const char* params_json);

/* Instantiation results below zero. */
#define LYRIC_WASMHOST_ERROR (-1)   /* the component could not be linked or the host failed */
#define LYRIC_WASMHOST_TRAP (-2)    /* the component trapped while starting */
#define LYRIC_WASMHOST_TIMEOUT (-3) /* starting it took longer than the timeout */

/* 1 when libwasmtime is loaded and an engine exists, 0 otherwise. */
LYRIC_WASMHOST_API int32_t lyric_wasmhost_available(void);

/* Why the embedding is unavailable ("" when it is available). */
LYRIC_WASMHOST_API char* lyric_wasmhost_unavailable_reason(void);

/* The message of the last failed call on this thread. */
LYRIC_WASMHOST_API char* lyric_wasmhost_last_error(void);

/* Compile the component at `path` and prepare its linker (WASI p2, every
 * other import a host import).  Returns a component id, or 0 with the reason
 * in `lyric_wasmhost_last_error`. */
LYRIC_WASMHOST_API int64_t lyric_wasmhost_load(const char* path);

/* Release a component.  Instances still open keep it alive until they close. */
LYRIC_WASMHOST_API void lyric_wasmhost_unload(int64_t component);

/* Instantiate a component in a new store whose linear memories are capped at
 * `max_memory_bytes`, with a WASI context that has no directories,
 * environment, arguments or network and inherits only stderr.  Starting is
 * bounded by `timeout_ms`.  `import_fn` serves the host imports; `userdata`
 * is handed back to it and returned by `lyric_wasmhost_close`.  Returns an
 * instance id, or one of the negative LYRIC_WASMHOST_* codes with the reason
 * in `lyric_wasmhost_last_error`. */
LYRIC_WASMHOST_API int64_t lyric_wasmhost_instantiate(int64_t component, int64_t max_memory_bytes, int32_t timeout_ms,
                                                      lyric_wasmhost_import_fn import_fn, void* userdata);

/* Call export `name` (found in the component's root or in any exported
 * instance) with the arguments in `params_json`, an object keyed by Lyric
 * parameter name (`null` for none), within `timeout_ms`.  Returns one JSON
 * envelope:
 *   {"ok": <result>}         the call returned (`null` when it has no result)
 *   {"trap": "<message>"}    the component trapped, or a host import failed
 *   {"timeout": <ms>}        the call ran past its deadline and was stopped
 *   {"missing": "<name>"}    no such export
 *   {"invalid": "<message>"} the arguments do not fit the export's types, or
 *                            its result cannot be written as JSON
 *   {"busy": "<message>"}    the instance is already running a call
 * After a trap or a timeout the instance cannot be called again; close it. */
LYRIC_WASMHOST_API char* lyric_wasmhost_call(int64_t instance, const char* name, const char* params_json,
                                             int32_t timeout_ms);

/* 1 when the instantiated component exports `name`, else 0. */
LYRIC_WASMHOST_API int32_t lyric_wasmhost_has_export(int64_t instance, const char* name);

/* Drop an instance and its store.  Returns its userdata (NULL for an unknown
 * id), so the caller can release what it kept for the callback. */
LYRIC_WASMHOST_API void* lyric_wasmhost_close(int64_t instance);

/* The shim's allocator, for strings that cross in either direction. */
LYRIC_WASMHOST_API char* lyric_wasmhost_alloc(int64_t size);
LYRIC_WASMHOST_API void lyric_wasmhost_free(char* p);

#ifdef __cplusplus
}
#endif

#endif
