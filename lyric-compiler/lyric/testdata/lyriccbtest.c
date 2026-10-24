/*
 * lyriccbtest.c: the C side of extern_callback_self_test.l (D229).
 *
 * Each function takes a callback and the userdata pointer C hands back to
 * it, the shape of every callback-driven C API.  scripts/ci/extern-callback-e2e.sh
 * builds this file into liblyriccbtest.so and runs the self-test against it on
 * --target dotnet, --target jvm and --target native.
 */
#include <pthread.h>
#include <stdint.h>
#include <stddef.h>

typedef int32_t (*int_cb)(int32_t, void *);
typedef void (*long_cb)(void *, int64_t);
typedef double (*double_cb)(double, void *);
typedef float (*float_cb)(float, void *);
typedef uint8_t (*byte_cb)(uint8_t, void *);
typedef void *(*ptr_cb)(void *, void *);

/* Calls f(i, ud) for i in 0 ..< n and returns the sum of the results. */
int32_t cbt_sum(int_cb f, void *ud, int32_t n) {
    int32_t total = 0;
    for (int32_t i = 0; i < n; i++) {
        total += f(i, ud);
    }
    return total;
}

/* Calls f(ud, i * 1e9) for i in 0 ..< n: userdata first, a Unit result and
   64-bit arguments. */
void cbt_each_long(long_cb f, void *ud, int64_t n) {
    for (int64_t i = 0; i < n; i++) {
        f(ud, i * 1000000000LL);
    }
}

double cbt_apply_double(double_cb f, void *ud, double x) {
    return f(x, ud);
}

float cbt_apply_float(float_cb f, void *ud, float x) {
    return f(x, ud);
}

uint8_t cbt_apply_byte(byte_cb f, void *ud, uint8_t x) {
    return f(x, ud);
}

void *cbt_apply_ptr(ptr_cb f, void *ud, void *p) {
    return f(p, ud);
}

/* Returns the userdata pointer it was given. */
void *cbt_echo(void *ud) {
    return ud;
}

/* A callback a C library keeps and calls on a later call. */
static int_cb stored_f;
static void *stored_ud;

void cbt_store(int_cb f, void *ud) {
    stored_f = f;
    stored_ud = ud;
}

int32_t cbt_call_stored(int32_t x) {
    return stored_f(x, stored_ud);
}

/* Calls f(x, ud) on a new thread and returns its result. */
struct cbt_thread_call {
    int_cb f;
    void *ud;
    int32_t x;
    int32_t result;
};

static void *cbt_thread_main(void *arg) {
    struct cbt_thread_call *c = (struct cbt_thread_call *)arg;
    c->result = c->f(c->x, c->ud);
    return NULL;
}

int32_t cbt_call_on_thread(int_cb f, void *ud, int32_t x) {
    struct cbt_thread_call c = {f, ud, x, -1};
    pthread_t t;
    if (pthread_create(&t, NULL, cbt_thread_main, &c) != 0) {
        return -2;
    }
    pthread_join(t, NULL);
    return c.result;
}
