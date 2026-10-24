/* lyric_wasmhost_test.c — unit tests for the in-process wasmtime shim.
 *
 *   lyric_wasmhost_test <fixture.wasm> <not-a-component-file>
 *
 * The fixture is test/wasmhost_fixture.wat built with `wasm-tools parse`;
 * libwasmtime comes from $LYRIC_WASMTIME_LIB.  `make -C lyric-rt
 * test-wasmhost WASMTIME_CAPI=<dir> WASM_TOOLS=<wasm-tools>` builds and runs
 * it (scripts/ci/fetch-wasmtime-capi.sh provides both).
 */
#define _POSIX_C_SOURCE 200809L
#include "lyric_wasmhost.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int g_failures;
static int g_checks;

static void check(int cond, const char* what) {
    g_checks++;
    if (!cond) {
        g_failures++;
        fprintf(stderr, "FAIL: %s\n", what);
    }
}

static void check_eq(const char* got, const char* want, const char* what) {
    g_checks++;
    if (got == NULL || strcmp(got, want) != 0) {
        g_failures++;
        fprintf(stderr, "FAIL: %s\n  want: %s\n  got:  %s\n", what, want, got ? got : "(null)");
    }
}

static void check_prefix(const char* got, const char* prefix, const char* what) {
    g_checks++;
    if (got == NULL || strncmp(got, prefix, strlen(prefix)) != 0) {
        g_failures++;
        fprintf(stderr, "FAIL: %s\n  want prefix: %s\n  got: %s\n", what, prefix, got ? got : "(null)");
    }
}

static void check_contains(const char* got, const char* needle, const char* what) {
    g_checks++;
    if (got == NULL || strstr(got, needle) == NULL) {
        g_failures++;
        fprintf(stderr, "FAIL: %s\n  want to contain: %s\n  got: %s\n", what, needle, got ? got : "(null)");
    }
}

static char* call(int64_t inst, const char* name, const char* params, int timeout_ms) {
    return lyric_wasmhost_call(inst, name, params, timeout_ms);
}

static void expect_call(int64_t inst, const char* name, const char* params, const char* want, const char* what) {
    char* got = call(inst, name, params, 5000);
    check_eq(got, want, what);
    lyric_wasmhost_free(got);
}

/* The host import: answers by question, and records what it was given. */
typedef struct {
    int calls;
    char last_instance[128];
    char last_func[64];
    char last_params[256];
} HostLog;

static char* host_answer(const char* json) {
    size_t n = strlen(json);
    char* r = lyric_wasmhost_alloc((int64_t)n + 1);
    memcpy(r, json, n + 1);
    return r;
}

static char* host_import(void* userdata, const char* instance, const char* func, const char* params) {
    HostLog* log = (HostLog*)userdata;
    log->calls++;
    snprintf(log->last_instance, sizeof(log->last_instance), "%s", instance);
    snprintf(log->last_func, sizeof(log->last_func), "%s", func);
    snprintf(log->last_params, sizeof(log->last_params), "%s", params);
    if (strstr(params, "\"ok\"")) return host_answer("{\"ok\":\"yes, granted\"}");
    if (strstr(params, "\"deny\"")) return host_answer("{\"err\":{\"case\":\"Denied\",\"reason\":\"not today\"}}");
    if (strstr(params, "\"missing\"")) return host_answer("{\"err\":{\"case\":\"NotGranted\",\"capability\":\"X.Y\"}}");
    if (strstr(params, "\"stale\"")) return host_answer("{\"err\":{\"case\":\"Stale\"}}");
    if (strstr(params, "\"garbage\"")) return host_answer("{\"err\":{\"case\":\"Nope\"}}");
    return NULL;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static const char* k_big_in =
    "{\"name\":\"widget \\\"w\\\"\\n\\u00e9\",\"count\":-9223372036854775808,\"ratio\":0.5,\"small\":1.5,"
    "\"flag\":true,\"tag\":255,\"id\":18446744073709551615,\"letter\":\"\\u03bb\",\"tags\":[\"a\",\"b\"],"
    "\"bytes\":\"AQID/w==\",\"maybe\":null,\"shape\":{\"case\":\"Circle\",\"radius\":2.5},\"color\":\"DarkGreen\","
    "\"pair\":[7,\"seven\"],\"outcome\":{\"err\":\"bad\"},\"attrs\":{\"x\":1,\"y\":-2},"
    "\"inner\":{\"x\":-3,\"y\":65535},\"tiny\":-128,\"wide\":4294967295,\"ignored\":[1,2,3]}";

static const char* k_big_out =
    "{\"ok\":{\"name\":\"widget \\\"w\\\"\\n\xc3\xa9\",\"count\":-9223372036854775808,\"ratio\":0.5,\"small\":1.5,"
    "\"flag\":true,\"tag\":255,\"id\":18446744073709551615,\"letter\":\"\xce\xbb\",\"tags\":[\"a\",\"b\"],"
    "\"bytes\":\"AQID/w==\",\"maybe\":null,\"shape\":{\"case\":\"Circle\",\"radius\":2.5},\"color\":\"DarkGreen\","
    "\"pair\":[7,\"seven\"],\"outcome\":{\"err\":\"bad\"},\"attrs\":{\"x\":1,\"y\":-2},"
    "\"inner\":{\"x\":-3,\"y\":65535},\"tiny\":-128,\"wide\":4294967295}}";

static const char* k_big2_in =
    "{\"name\":\"\",\"count\":0,\"ratio\":-1e300,\"small\":0,\"flag\":false,\"tag\":0,\"id\":0,\"letter\":\"a\","
    "\"tags\":[],\"bytes\":\"\",\"maybe\":\"there\",\"shape\":{\"case\":\"Named\",\"label\":\"sq\"},\"color\":\"Red\","
    "\"pair\":[-1,\"\"],\"outcome\":{\"ok\":3},\"attrs\":[[\"k\",9]],\"inner\":{\"x\":0,\"y\":0},\"tiny\":127,"
    "\"wide\":0}";

static const char* k_big2_out =
    "{\"ok\":{\"name\":\"\",\"count\":0,\"ratio\":-1.0000000000000001e+300,\"small\":0,\"flag\":false,\"tag\":0,"
    "\"id\":0,\"letter\":\"a\",\"tags\":[],\"bytes\":\"\",\"maybe\":\"there\",\"shape\":{\"case\":\"Named\","
    "\"label\":\"sq\"},\"color\":\"Red\",\"pair\":[-1,\"\"],\"outcome\":{\"ok\":3},\"attrs\":{\"k\":9},"
    "\"inner\":{\"x\":0,\"y\":0},\"tiny\":127,\"wide\":0}}";

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <fixture.wasm> <not-a-component>\n", argv[0]);
        return 2;
    }
    char* reason = lyric_wasmhost_unavailable_reason();
    if (!lyric_wasmhost_available()) {
        fprintf(stderr, "libwasmtime did not load: %s\n", reason);
        lyric_wasmhost_free(reason);
        return 1;
    }
    check_eq(reason, "", "no unavailable reason once loaded");
    lyric_wasmhost_free(reason);

    /* Loading. */
    check(lyric_wasmhost_load("/nonexistent/plugin.wasm") == 0, "a missing file does not load");
    char* err = lyric_wasmhost_last_error();
    check_contains(err, "cannot open component", "a missing file names the problem");
    lyric_wasmhost_free(err);
    check(lyric_wasmhost_load(argv[2]) == 0, "a file that is not a component does not load");
    err = lyric_wasmhost_last_error();
    check_contains(err, "is not a valid component", "an invalid component names the problem");
    lyric_wasmhost_free(err);

    int64_t comp = lyric_wasmhost_load(argv[1]);
    check(comp > 0, "the fixture loads");
    if (comp <= 0) {
        err = lyric_wasmhost_last_error();
        fprintf(stderr, "load: %s\n", err);
        lyric_wasmhost_free(err);
        return 1;
    }

    HostLog log;
    memset(&log, 0, sizeof(log));
    int64_t inst = lyric_wasmhost_instantiate(comp, 64ll << 20, 5000, host_import, &log);
    check(inst > 0, "the fixture instantiates");
    if (inst <= 0) {
        err = lyric_wasmhost_last_error();
        fprintf(stderr, "instantiate: %s\n", err);
        lyric_wasmhost_free(err);
        return 1;
    }
    check(lyric_wasmhost_has_export(inst, "identity") == 1, "has_export finds an export");
    check(lyric_wasmhost_has_export(inst, "nothing") == 0, "has_export rejects an unknown name");

    /* Scalars, names and strings. */
    expect_call(inst, "add", "{\"leftSide\":2,\"rightSide\":40}", "{\"ok\":42}", "add maps camel parameter names");
    expect_call(inst, "add", "{\"leftSide\":2147483647,\"rightSide\":1}", "{\"ok\":-2147483648}", "s32 wraps in the guest");
    expect_call(inst, "echo", "{\"text\":\"h\\u00e9llo \\\"q\\\"\\t\\\\ \\ud83d\\ude00\"}",
                "{\"ok\":\"h\xc3\xa9llo \\\"q\\\"\\t\\\\ \xf0\x9f\x98\x80\"}", "strings round-trip with escapes");

    /* Every boundary value kind, through linear memory, with hints. */
    expect_call(inst, "identity", (const char*)NULL == NULL ? "" : "", "{\"invalid\":\"missing parameter 'value'\"}",
                "an absent params object is a missing parameter");
    {
        char params[2048];
        snprintf(params, sizeof(params), "{\"value\":%s}", k_big_in);
        expect_call(inst, "identity", params, k_big_out, "a big record round-trips");
        snprintf(params, sizeof(params), "{\"value\":%s}", k_big2_in);
        expect_call(inst, "identity", params, k_big2_out, "other cases, an array-of-pairs map and empties round-trip");
    }

    /* Bad arguments. */
    char* r = call(inst, "add", "{\"leftSide\":1}", 5000);
    check_eq(r, "{\"invalid\":\"missing parameter 'rightSide'\"}", "a missing parameter is invalid");
    lyric_wasmhost_free(r);
    r = call(inst, "add", "{\"leftSide\":1,\"rightSide\":2147483648}", 5000);
    check_prefix(r, "{\"invalid\":\"parameter 'rightSide': 2147483648 is out of range", "an out-of-range integer is invalid");
    lyric_wasmhost_free(r);
    r = call(inst, "add", "{\"leftSide\":1.5,\"rightSide\":2}", 5000);
    check_prefix(r, "{\"invalid\":\"parameter 'leftSide': expected an integer", "a fraction is not an integer");
    lyric_wasmhost_free(r);
    r = call(inst, "add", "{\"leftSide\":1,", 5000);
    check_prefix(r, "{\"invalid\":\"malformed JSON", "malformed params are invalid");
    lyric_wasmhost_free(r);
    r = call(inst, "add", "[1,2]", 5000);
    check_eq(r, "{\"invalid\":\"call params must be an object keyed by parameter name\"}", "params must be an object");
    lyric_wasmhost_free(r);
    {
        char params[2048];
        snprintf(params, sizeof(params), "{\"value\":%s}", k_big_in);
        char* p = strstr(params, "Circle");
        memcpy(p, "Square", 6);
        r = call(inst, "identity", params, 5000);
        check_eq(r, "{\"invalid\":\"parameter 'value': shape: unknown case \\\"Square\\\"\"}", "an unknown case is invalid");
        lyric_wasmhost_free(r);
        snprintf(params, sizeof(params), "{\"value\":%s}", k_big_in);
        p = strstr(params, "DarkGreen");
        memcpy(p, "darkGreen", 9);
        r = call(inst, "identity", params, 5000);
        check_eq(r, "{\"invalid\":\"parameter 'value': color: unknown enum case \\\"darkGreen\\\"\"}",
                 "enum names are Pascal case");
        lyric_wasmhost_free(r);
        snprintf(params, sizeof(params), "{\"value\":%s}", k_big_in);
        p = strstr(params, "AQID/w==");
        memcpy(p, "AQID/w=!", 8);
        r = call(inst, "identity", params, 5000);
        check_eq(r, "{\"invalid\":\"parameter 'value': bytes: expected base64 for a List[Byte]\"}", "bad base64 is invalid");
        lyric_wasmhost_free(r);
    }
    r = call(inst, "nothing-here", "{}", 5000);
    check_eq(r, "{\"missing\":\"nothing-here\"}", "an unknown export is missing");
    lyric_wasmhost_free(r);

    /* Host imports. */
    expect_call(inst, "ask-host", "{\"question\":\"ok\"}", "{\"ok\":{\"ok\":\"yes, granted\"}}", "an import answers ok");
    check_eq(log.last_instance, "lyric:test/host-api", "the import names its instance");
    check_eq(log.last_func, "ask", "the import names its function");
    check_eq(log.last_params, "{\"question\":\"ok\"}", "the import's arguments are an object by parameter name");
    expect_call(inst, "ask-host", "{\"question\":\"deny\"}", "{\"ok\":{\"err\":{\"case\":\"Denied\",\"reason\":\"not today\"}}}",
                "an import answers a boundary error, named by the hints");
    expect_call(inst, "ask-host", "{\"question\":\"missing\"}",
                "{\"ok\":{\"err\":{\"case\":\"NotGranted\",\"capability\":\"X.Y\"}}}", "kebab cases map to Pascal");
    expect_call(inst, "ask-host", "{\"question\":\"stale\"}", "{\"ok\":{\"err\":{\"case\":\"Stale\"}}}",
                "a payload-less case");
    check(log.calls == 4, "the import ran once per call");
    r = call(inst, "ask-host", "{\"question\":\"garbage\"}", 5000);
    check_prefix(r, "{\"trap\":\"the host's answer to lyric:test/host-api#ask does not fit its result type",
                 "an ill-typed answer traps the guest");
    lyric_wasmhost_free(r);
    r = call(inst, "add", "{\"leftSide\":1,\"rightSide\":1}", 5000);
    check_prefix(r, "{\"trap\":\"the instance trapped or timed out earlier", "a trapped instance cannot be called");
    lyric_wasmhost_free(r);
    check(lyric_wasmhost_close(inst) == &log, "close returns the userdata");
    check(lyric_wasmhost_close(inst) == NULL, "closing twice is harmless");

    /* A host that answers nothing traps the call. */
    inst = lyric_wasmhost_instantiate(comp, 64ll << 20, 5000, host_import, &log);
    r = call(inst, "ask-host", "{\"question\":\"silence\"}", 5000);
    check_eq(r, "{\"trap\":\"the host failed to answer lyric:test/host-api#ask\"}", "a NULL answer traps");
    lyric_wasmhost_free(r);
    lyric_wasmhost_close(inst);

    /* Traps, and a fresh instance after one. */
    inst = lyric_wasmhost_instantiate(comp, 64ll << 20, 5000, host_import, &log);
    r = call(inst, "boom", "{}", 5000);
    check_prefix(r, "{\"trap\":", "unreachable traps");
    check_contains(r, "unreachable", "the trap says why");
    lyric_wasmhost_free(r);
    lyric_wasmhost_close(inst);
    inst = lyric_wasmhost_instantiate(comp, 64ll << 20, 5000, host_import, &log);
    expect_call(inst, "add", "{\"leftSide\":1,\"rightSide\":2}", "{\"ok\":3}", "a re-instantiated plugin runs");

    /* Timeouts: a CPU loop that never yields is stopped by the epoch. */
    double t0 = now_ms();
    r = call(inst, "spin", "{}", 300);
    double elapsed = now_ms() - t0;
    check_eq(r, "{\"timeout\":300}", "an endless loop times out");
    lyric_wasmhost_free(r);
    check(elapsed >= 290.0 && elapsed < 2000.0, "the timeout fires near its deadline");
    fprintf(stderr, "timeout: a 300 ms deadline stopped the loop after %.0f ms\n", elapsed);
    lyric_wasmhost_close(inst);

    /* The memory limit. */
    inst = lyric_wasmhost_instantiate(comp, 1ll << 20, 5000, host_import, &log);
    expect_call(inst, "grow", "{\"pages\":4}", "{\"ok\":1}", "growth under the limit succeeds");
    expect_call(inst, "grow", "{\"pages\":100}", "{\"ok\":-1}", "growth past a 1 MiB limit fails");
    expect_call(inst, "grow", "{\"pages\":11}", "{\"ok\":5}", "growth up to the limit succeeds");
    expect_call(inst, "grow", "{\"pages\":1}", "{\"ok\":-1}", "one page past the limit fails");
    lyric_wasmhost_close(inst);
    inst = lyric_wasmhost_instantiate(comp, 64ll << 20, 5000, host_import, &log);
    expect_call(inst, "grow", "{\"pages\":100}", "{\"ok\":1}", "a larger limit allows the growth");
    lyric_wasmhost_close(inst);
    int64_t tiny = lyric_wasmhost_instantiate(comp, 1024, 5000, host_import, &log);
    check(tiny == LYRIC_WASMHOST_ERROR || tiny == LYRIC_WASMHOST_TRAP, "a limit below the initial memory fails to start");
    err = lyric_wasmhost_last_error();
    fprintf(stderr, "memory: a 1 KiB limit refuses the 64 KiB initial memory: %s\n", err);
    lyric_wasmhost_free(err);

    check(lyric_wasmhost_instantiate(999999, 1 << 20, 5000, host_import, &log) == LYRIC_WASMHOST_ERROR,
          "an unknown component id is an error");
    lyric_wasmhost_unload(comp);
    check(lyric_wasmhost_instantiate(comp, 1 << 20, 5000, host_import, &log) == LYRIC_WASMHOST_ERROR,
          "an unloaded component cannot be instantiated");

    if (g_failures == 0) {
        printf("lyric_wasmhost_test: all %d checks passed\n", g_checks);
        return 0;
    }
    printf("lyric_wasmhost_test: %d of %d checks failed\n", g_failures, g_checks);
    return 1;
}
