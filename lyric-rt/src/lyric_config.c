/* lyric_config.c -- startup reads of `config { }` fields (docs/25, #7435).
 *
 * The native backend lowers each config field to a module-level global whose
 * initializer calls one of the readers below (through `Std.ConfigHost`), so
 * the environment is read once, before `main`.  The behaviour is that of the
 * dotnet and JVM lowerings:
 *
 *   - the env var is `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>`; an unset or empty
 *     variable takes the field's default, or, with none, stops startup with
 *     exit 78 and "required config field ... is not set";
 *   - a value that does not parse as the field's type stops startup with exit
 *     78 and G0003.  An Int/Long accepts a sign and surrounding whitespace, a
 *     Float/Double the C-locale float format (the process never calls
 *     setlocale, so `1,5` is not 1.5), a Bool exactly `1`, `0` or
 *     `true`/`false` in any case, and a String is taken unmodified;
 *   - a parsed value outside the field's range stops startup with exit 78 and
 *     the "is outside its range" message (G0004).  NaN is outside every
 *     floating range.
 *
 * Every message goes to stderr and never echoes the value.
 */
#include "lyric_rt.h"

#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CONFIG_EXIT_CODE 78

typedef struct {
    char* env;
    char* label;
    char* range_desc;
} ConfigNames;

static char* dup_lyric_string(LyricString* s) {
    int64_t n = s ? s->len : 0;
    char* out = (char*)malloc((size_t)n + 1);
    if (!out) lyric_panic_msg("out of memory reading a config field", "lyric_config.c", __LINE__);
    if (n > 0) memcpy(out, LYRIC_STRING_DATA(s), (size_t)n);
    out[n] = '\0';
    return out;
}

static ConfigNames names_of(LyricString* env, LyricString* label, LyricString* range_desc) {
    ConfigNames n;
    n.env = dup_lyric_string(env);
    n.label = dup_lyric_string(label);
    n.range_desc = dup_lyric_string(range_desc);
    return n;
}

static void names_free(ConfigNames* n) {
    free(n->env);
    free(n->label);
    free(n->range_desc);
}

static _Noreturn void config_exit(void) {
    fflush(stdout);
    fflush(stderr);
    exit(CONFIG_EXIT_CODE);
}

static _Noreturn void fail_required(const ConfigNames* n) {
    fprintf(stderr, "error: required config field %s (env var %s) is not set\n", n->label, n->env);
    config_exit();
}

static _Noreturn void fail_parse(const ConfigNames* n, const char* type_name) {
    fprintf(stderr, "error: config field %s (env var %s) is not a valid %s (G0003)\n", n->label, n->env, type_name);
    config_exit();
}

static _Noreturn void fail_range(const ConfigNames* n) {
    fprintf(stderr, "error: config field %s (env var %s) is outside its range %s\n", n->label, n->env, n->range_desc);
    config_exit();
}

/* The env var's value when set and non-empty; NULL otherwise (unset and empty
 * are the same "absent" case on every target).  The caller frees it. */
static char* env_value(const ConfigNames* n) {
    LyricString* v = lyric_env_get(n->env);
    if (!v) return NULL;
    char* out = dup_lyric_string(v);
    lyric_release(v);
    if (out[0] == '\0') {
        free(out);
        return NULL;
    }
    return out;
}

/* Trims leading and trailing white space in place; returns the first byte. */
static char* trim(char* s) {
    while (*s != '\0' && isspace((unsigned char)*s)) s++;
    size_t n = strlen(s);
    while (n > 0 && isspace((unsigned char)s[n - 1])) n--;
    s[n] = '\0';
    return s;
}

static int parse_integer(char* raw, int64_t* out) {
    char* s = trim(raw);
    if (*s == '\0') return 0;
    errno = 0;
    char* end = NULL;
    long long v = strtoll(s, &end, 10);
    if (errno == ERANGE || end == s || *end != '\0') return 0;
    *out = (int64_t)v;
    return 1;
}

static int integer_in_range(int64_t v, int has_min, int64_t lo, int has_max, int64_t hi, int upper_exclusive) {
    if (has_min && v < lo) return 0;
    if (has_max && (upper_exclusive ? v >= hi : v > hi)) return 0;
    return 1;
}

static int64_t read_integer(
    LyricString* env, LyricString* label, LyricString* range_desc, const char* type_name, int64_t type_min,
    int64_t type_max, int32_t has_default, int64_t def, int32_t has_min, int64_t lo, int32_t has_max, int64_t hi,
    int32_t upper_exclusive
) {
    ConfigNames n = names_of(env, label, range_desc);
    char* raw = env_value(&n);
    int64_t v = def;
    if (raw) {
        int ok = parse_integer(raw, &v) && v >= type_min && v <= type_max;
        free(raw);
        if (!ok) fail_parse(&n, type_name);
    } else if (!has_default) {
        fail_required(&n);
    }
    if (!integer_in_range(v, has_min, lo, has_max, hi, upper_exclusive)) fail_range(&n);
    names_free(&n);
    return v;
}

int32_t lyric_config_int(
    LyricString* env, LyricString* label, LyricString* range_desc, int32_t has_default, int32_t def,
    int32_t has_min, int64_t lo, int32_t has_max, int64_t hi, int32_t upper_exclusive
) {
    return (int32_t)read_integer(
        env, label, range_desc, "Int", INT32_MIN, INT32_MAX, has_default, def, has_min, lo, has_max, hi,
        upper_exclusive
    );
}

int64_t lyric_config_long(
    LyricString* env, LyricString* label, LyricString* range_desc, int32_t has_default, int64_t def,
    int32_t has_min, int64_t lo, int32_t has_max, int64_t hi, int32_t upper_exclusive
) {
    return read_integer(
        env, label, range_desc, "Long", INT64_MIN, INT64_MAX, has_default, def, has_min, lo, has_max, hi,
        upper_exclusive
    );
}

/* NaN fails every comparison below, so it is outside every range. */
static int floating_in_range(double v, int has_min, double lo, int has_max, double hi, int upper_exclusive) {
    if (has_min && !(v >= lo)) return 0;
    if (has_max && !(upper_exclusive ? v < hi : v <= hi)) return 0;
    return 1;
}

double lyric_config_double(
    LyricString* env, LyricString* label, LyricString* range_desc, int32_t has_default, double def,
    int32_t has_min, double lo, int32_t has_max, double hi, int32_t upper_exclusive
) {
    ConfigNames n = names_of(env, label, range_desc);
    char* raw = env_value(&n);
    double v = def;
    if (raw) {
        char* s = trim(raw);
        char* end = NULL;
        v = strtod(s, &end);
        int ok = *s != '\0' && end != s && *end == '\0';
        free(raw);
        if (!ok) fail_parse(&n, "Double");
    } else if (!has_default) {
        fail_required(&n);
    }
    if (!floating_in_range(v, has_min, lo, has_max, hi, upper_exclusive)) fail_range(&n);
    names_free(&n);
    return v;
}

float lyric_config_float(
    LyricString* env, LyricString* label, LyricString* range_desc, int32_t has_default, float def,
    int32_t has_min, float lo, int32_t has_max, float hi, int32_t upper_exclusive
) {
    ConfigNames n = names_of(env, label, range_desc);
    char* raw = env_value(&n);
    float v = def;
    if (raw) {
        char* s = trim(raw);
        char* end = NULL;
        v = strtof(s, &end);
        int ok = *s != '\0' && end != s && *end == '\0';
        free(raw);
        if (!ok) fail_parse(&n, "Float");
    } else if (!has_default) {
        fail_required(&n);
    }
    if (!floating_in_range((double)v, has_min, (double)lo, has_max, (double)hi, upper_exclusive)) fail_range(&n);
    names_free(&n);
    return v;
}

static int equals_ignore_case(const char* a, const char* b) {
    for (; *a != '\0' && *b != '\0'; a++, b++) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 0;
    }
    return *a == *b;
}

int32_t lyric_config_bool(LyricString* env, LyricString* label, int32_t has_default, int32_t def) {
    ConfigNames n = names_of(env, label, label);
    char* raw = env_value(&n);
    int32_t v = def;
    if (raw) {
        int is_true = strcmp(raw, "1") == 0 || equals_ignore_case(raw, "true");
        int is_false = strcmp(raw, "0") == 0 || equals_ignore_case(raw, "false");
        free(raw);
        if (!is_true && !is_false) fail_parse(&n, "Bool");
        v = is_true ? 1 : 0;
    } else if (!has_default) {
        fail_required(&n);
    }
    names_free(&n);
    return v;
}

/* The field's String, an owned reference: the env value unmodified, or `def`
 * (retained) when the variable is absent. */
LyricString* lyric_config_string(LyricString* env, LyricString* label, int32_t has_default, LyricString* def) {
    ConfigNames n = names_of(env, label, label);
    LyricString* v = lyric_env_get(n.env);
    if (v && v->len == 0) {
        lyric_release(v);
        v = NULL;
    }
    if (!v) {
        if (!has_default) fail_required(&n);
        v = lyric_string_from_literal(LYRIC_STRING_DATA(def), def->len);
    }
    names_free(&n);
    return v;
}
