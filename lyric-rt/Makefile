# lyric-rt — the Lyric native runtime static library.
#
#   make            -> build/lyric_rt.a
#   make test       -> build and run the C unit tests
#   make clean
#
# CC defaults to clang (the toolchain the native backend drives; D-N-001)
# but any C11 compiler works.
#
# wasm32-wasi (docs/35 W2) is a second, cross-compiled build of the same
# runtime with a pinned wasi-sdk:
#
#   make wasm32-wasi      WASI_SDK=/opt/wasi-sdk   -> build/wasm32-wasi/lyric_rt.a
#   make test-wasm32-wasi WASI_SDK=/opt/wasi-sdk WASMTIME=wasmtime
#
# lyric_process.c and lyric_tls.c are replaced by their *_unsupported.c
# twins there (WASI has no child processes, BSD sockets or dlopen); the
# twins keep every symbol resolvable and report the documented failure.

CC      ?= clang
AR      ?= ar
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Werror -fPIC
BUILD   := build

SRCS := src/lyric_rt.c src/lyric_string.c src/lyric_weak.c \
        src/lyric_posix.c src/lyric_collections.c src/lyric_async.c \
        src/lyric_fs.c src/lyric_process.c src/lyric_tls.c
OBJS := $(SRCS:src/%.c=$(BUILD)/%.o)

# The TLS seam dlopen's OpenSSL at runtime (no link-time -lssl/-lcrypto);
# it needs libdl (a no-op stub on glibc >= 2.34) and libpthread.
TEST_LIBS := -lpthread -ldl

.PHONY: all test test-asan clean wasm32-wasi test-wasm32-wasi

all: $(BUILD)/lyric_rt.a

$(BUILD)/%.o: src/%.c include/lyric_rt.h | $(BUILD)
	$(CC) $(CFLAGS) -Iinclude -c $< -o $@

# lyric_string.c #includes the generated Unicode case-folding tables
# (#6779); list it explicitly so editing the .inc alone triggers a rebuild.
$(BUILD)/lyric_string.o: src/lyric_unicode_case_tables.inc

$(BUILD)/lyric_rt.a: $(OBJS)
	$(AR) rcs $@ $(OBJS)

$(BUILD):
	mkdir -p $(BUILD)

test: $(BUILD)/lyric_rt.a
	$(CC) $(CFLAGS) -Iinclude test/lyric_rt_test.c $(BUILD)/lyric_rt.a $(TEST_LIBS) -o $(BUILD)/lyric_rt_test
	$(BUILD)/lyric_rt_test
	$(CC) $(CFLAGS) -Iinclude test/lyric_tls_test.c $(BUILD)/lyric_rt.a $(TEST_LIBS) -o $(BUILD)/lyric_tls_test
	$(BUILD)/lyric_tls_test

# ASan variant of the TLS seam test, kept OUT of the default `test` target
# because it needs the compiler's AddressSanitizer runtime, which is not
# universally installed for every C compiler (clang without compiler-rt).
# Compiles the self-contained seam (src/lyric_tls.c — libc + dlopen'd OpenSSL
# only) together with the test from source so the seam code (sockets, PEM /
# context glue, handshake I/O) is fully instrumented: a leaked SSL_CTX / SSL /
# fd / alpn buffer, a use-after-free, or an overflow in a handshake round-trip
# fails the run (the llvm_*_self_test ASan discipline).  src/lyric_string.c +
# src/lyric_rt.c + src/lyric_weak.c + src/lyric_collections.c are pulled in
# too (not part of the seam itself): lyric_tls_last_error_string/
# lyric_tls_alpn_string return a genuine LyricString* and
# lyric_{sock,tls}_{read,write}_bytes bridge through a genuine LyricList*
# (issue #6103 item C), and the test exercises both via
# lyric_string_len/lyric_list_len/lyric_release, so ASan needs those
# allocations instrumented too, not just the seam's raw malloc'd handles
# (lyric_release pulls in lyric_weak_release even though these values are
# never weakly referenced).  Run under a compiler with ASan (gcc's libasan
# is reliably present): `make test-asan CC=gcc`.
test-asan: | $(BUILD)
	$(CC) $(CFLAGS) -fsanitize=address -Iinclude test/lyric_tls_test.c src/lyric_tls.c src/lyric_string.c src/lyric_rt.c src/lyric_weak.c src/lyric_collections.c $(TEST_LIBS) -o $(BUILD)/lyric_tls_test_asan
	$(BUILD)/lyric_tls_test_asan

# ── wasm32-wasi ──────────────────────────────────────────────────────────
WASI_SDK    ?=
WASMTIME    ?= wasmtime
WASM_BUILD  := $(BUILD)/wasm32-wasi
WASM_CC     := $(WASI_SDK)/bin/clang
WASM_AR     := $(WASI_SDK)/bin/llvm-ar
WASM_CFLAGS := --target=wasm32-wasi --sysroot=$(WASI_SDK)/share/wasi-sysroot -O2 -std=c11 -Wall -Wextra -Werror
WASM_SRCS   := src/lyric_rt.c src/lyric_string.c src/lyric_weak.c \
               src/lyric_posix.c src/lyric_collections.c src/lyric_async.c \
               src/lyric_fs.c src/lyric_process_unsupported.c src/lyric_net_unsupported.c
WASM_OBJS   := $(WASM_SRCS:src/%.c=$(WASM_BUILD)/%.o)

$(WASM_BUILD)/%.o: src/%.c include/lyric_rt.h | $(WASM_BUILD)
	@test -n "$(WASI_SDK)" || { echo "set WASI_SDK to a wasi-sdk install (see docs/35 §5.1)"; exit 1; }
	$(WASM_CC) $(WASM_CFLAGS) -Iinclude -c $< -o $@

$(WASM_BUILD)/lyric_string.o: src/lyric_unicode_case_tables.inc

$(WASM_BUILD)/lyric_rt.a: $(WASM_OBJS)
	$(WASM_AR) rcs $@ $(WASM_OBJS)

$(WASM_BUILD):
	mkdir -p $(WASM_BUILD)

wasm32-wasi: $(WASM_BUILD)/lyric_rt.a

# The unit tests that need fork, pthreads, signals, processes or TLS are
# compiled out under __wasi__; the rest run under a WASI runtime.
test-wasm32-wasi: $(WASM_BUILD)/lyric_rt.a
	$(WASM_CC) $(WASM_CFLAGS) -Iinclude test/lyric_rt_test.c $(WASM_BUILD)/lyric_rt.a -o $(WASM_BUILD)/lyric_rt_test.wasm
	$(WASMTIME) run --dir=. $(WASM_BUILD)/lyric_rt_test.wasm

clean:
	rm -rf $(BUILD)
