# lyric-rt — the Lyric native runtime static library.
#
#   make            -> build/lyric_rt.a
#   make test       -> build and run the C unit tests
#   make clean              (host build only)
#   make clean-wasm32-wasi
#
# CC defaults to clang (the toolchain the native backend drives; D-N-001)
# but any C11 compiler works.
#
# wasm32-wasi (docs/35 W2) is a second, cross-compiled build of the same
# runtime with a pinned wasi-sdk:
#
#   make wasm32-wasi      WASI_SDK=/opt/wasi-sdk   -> build-wasm32-wasi/lyric_rt.a
#   make test-wasm32-wasi WASI_SDK=/opt/wasi-sdk WASMTIME=wasmtime
#
# lyric_process.c and lyric_tls.c are replaced by their *_unsupported.c
# twins there (WASI has no child processes, BSD sockets or dlopen); the
# twins keep every symbol resolvable and report the documented failure.
#
# x86_64-pc-windows-msvc (docs/67 G9) is a third build, with clang on Windows
# or cross-compiled from Linux against an MSVC CRT and Windows SDK named by
# the INCLUDE and LIB environment variables (for example a sysroot unpacked
# by xwin):
#
#   make windows        -> build-x86_64-pc-windows-msvc/lyric_rt.lib (and
#                          lyric_rt_md.lib, for AddressSanitizer builds)
#   make test-windows   [WINE=wine when cross-compiling]
#
# lyric_posix.c, lyric_fs.c, lyric_process.c and lyric_tls.c are replaced by
# their Win32 twins (lyric_win32.c, lyric_fs_win32.c, lyric_process_win32.c,
# and lyric_sock_win32.c with lyric_tls_win32.c, which uses Schannel).

CC      ?= clang
AR      ?= ar
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Werror -fPIC
BUILD   := build

SRCS := src/lyric_rt.c src/lyric_string.c src/lyric_weak.c \
        src/lyric_posix.c src/lyric_collections.c src/lyric_async.c \
        src/lyric_fs.c src/lyric_process.c src/lyric_tls.c src/lyric_parallel.c
OBJS := $(SRCS:src/%.c=$(BUILD)/%.o)

# The TLS seam dlopen's OpenSSL at runtime (no link-time -lssl/-lcrypto);
# it needs libdl (a no-op stub on glibc >= 2.34) and libpthread.
TEST_LIBS := -lpthread -ldl

# The release/acquire fence in lyric_release is invisible to gcc's ThreadSanitizer, which then
# reports the free of an object another thread dropped its last reference to as a race;
# clang's models fences, so the scheduler sanitizer runs always use clang.
SAN_CC ?= clang

# What the scheduler test needs when it is compiled from source under a sanitizer.
ASYNC_SANITIZED_SRCS := src/lyric_async.c src/lyric_rt.c src/lyric_weak.c src/lyric_posix.c \
                        src/lyric_string.c src/lyric_collections.c

.PHONY: all test test-asan test-asan-async test-tsan clean clean-wasm32-wasi wasm32-wasi wasm32-wasi-ir test-wasm32-wasi windows test-windows clean-windows

all: $(BUILD)/lyric_rt.a

$(BUILD)/%.o: src/%.c include/lyric_rt.h | $(BUILD)
	$(CC) $(CFLAGS) -Iinclude -c $< -o $@

# lyric_string.c #includes the generated Unicode case-folding tables
# (#6779); list it explicitly so editing the .inc alone triggers a rebuild.
$(BUILD)/lyric_string.o: src/lyric_unicode_case_tables.inc src/lyric_unicode_category_tables.inc

$(BUILD)/lyric_rt.a: $(OBJS)
	$(AR) rcs $@ $(OBJS)

$(BUILD):
	mkdir -p $(BUILD)

test: $(BUILD)/lyric_rt.a
	$(CC) $(CFLAGS) -Iinclude test/lyric_rt_test.c $(BUILD)/lyric_rt.a $(TEST_LIBS) -o $(BUILD)/lyric_rt_test
	$(BUILD)/lyric_rt_test
	$(CC) $(CFLAGS) -Iinclude test/lyric_tls_test.c $(BUILD)/lyric_rt.a $(TEST_LIBS) -o $(BUILD)/lyric_tls_test
	$(BUILD)/lyric_tls_test
	$(CC) $(CFLAGS) -Iinclude test/lyric_parallel_test.c $(BUILD)/lyric_rt.a $(TEST_LIBS) -o $(BUILD)/lyric_parallel_test
	$(BUILD)/lyric_parallel_test
	LYRIC_THREADS=1 $(BUILD)/lyric_parallel_test --serial
	LYRIC_THREADS=3 $(BUILD)/lyric_parallel_test
	$(CC) $(CFLAGS) -Iinclude test/lyric_async_mt_test.c $(BUILD)/lyric_rt.a $(TEST_LIBS) -o $(BUILD)/lyric_async_mt_test
	$(BUILD)/lyric_async_mt_test

# ThreadSanitizer run of the worker pool (docs/67 G8): the pool and its test are compiled from source
# with -fsanitize=thread, so a missing happens-before edge between a worker's writes and the caller's
# reads, a race on the job, or a use of the job after the caller returned fails the run.
# `make test-tsan`
test-tsan: | $(BUILD)
	$(CC) $(CFLAGS) -fsanitize=thread -Iinclude test/lyric_parallel_test.c src/lyric_parallel.c $(TEST_LIBS) -o $(BUILD)/lyric_parallel_test_tsan
	$(BUILD)/lyric_parallel_test_tsan
	LYRIC_THREADS=3 $(BUILD)/lyric_parallel_test_tsan
	$(SAN_CC) $(CFLAGS) -fsanitize=thread -Iinclude test/lyric_async_mt_test.c $(ASYNC_SANITIZED_SRCS) $(TEST_LIBS) -o $(BUILD)/lyric_async_mt_test_tsan
	TSAN_OPTIONS="halt_on_error=1 exitcode=66" $(BUILD)/lyric_async_mt_test_tsan

# AddressSanitizer run of the multi-threaded coroutine scheduler (docs/67 G8, D217): a frame
# destroyed while running, a task freed while still queued, or a leaked task fails the run.
# `make test-asan-async`
test-asan-async: | $(BUILD)
	$(SAN_CC) $(CFLAGS) -fsanitize=address -Iinclude test/lyric_async_mt_test.c $(ASYNC_SANITIZED_SRCS) $(TEST_LIBS) -o $(BUILD)/lyric_async_mt_test_asan
	$(BUILD)/lyric_async_mt_test_asan

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
# never weakly referenced).  src/lyric_posix.c supplies the test's threads,
# sleeps and clock.  Run under a compiler with ASan (gcc's libasan is
# reliably present): `make test-asan CC=gcc`.
test-asan: | $(BUILD)
	$(CC) $(CFLAGS) -fsanitize=address -Iinclude test/lyric_tls_test.c src/lyric_tls.c src/lyric_string.c src/lyric_rt.c src/lyric_weak.c src/lyric_collections.c src/lyric_posix.c $(TEST_LIBS) -o $(BUILD)/lyric_tls_test_asan
	$(BUILD)/lyric_tls_test_asan

# ── wasm32-wasi ──────────────────────────────────────────────────────────
WASI_SDK    ?=
WASMTIME    ?= wasmtime
WASM_BUILD  := build-wasm32-wasi
WASM_CC     := $(WASI_SDK)/bin/clang
WASM_AR     := $(WASI_SDK)/bin/llvm-ar
WASM_CFLAGS := --target=wasm32-wasip1 --sysroot=$(WASI_SDK)/share/wasi-sysroot -O2 -std=c11 -Wall -Wextra -Werror
WASM_SRCS   := src/lyric_rt.c src/lyric_string.c src/lyric_weak.c \
               src/lyric_posix.c src/lyric_collections.c src/lyric_async.c \
               src/lyric_fs.c src/lyric_process_unsupported.c src/lyric_net_unsupported.c \
               src/lyric_wasm.c src/lyric_wasm_async.c src/lyric_parallel.c
WASM_OBJS   := $(WASM_SRCS:src/%.c=$(WASM_BUILD)/%.o)

$(WASM_BUILD)/%.o: src/%.c include/lyric_rt.h | $(WASM_BUILD)
	@test -n "$(WASI_SDK)" || { echo "set WASI_SDK to a wasi-sdk install (see docs/35 §5.1)"; exit 1; }
	$(WASM_CC) $(WASM_CFLAGS) -Iinclude -c $< -o $@

$(WASM_BUILD)/lyric_string.o: src/lyric_unicode_case_tables.inc src/lyric_unicode_category_tables.inc

# LLVM IR of the wasm32 runtime, for scripts/audit-native-extern-abi.sh: the
# `define` lines are the exact C ABI each kernel extern must match.
WASM_IR := $(WASM_SRCS:src/%.c=$(WASM_BUILD)/ir/%.ll)

$(WASM_BUILD)/ir/%.ll: src/%.c include/lyric_rt.h src/lyric_unicode_case_tables.inc src/lyric_unicode_category_tables.inc
	@test -n "$(WASI_SDK)" || { echo "set WASI_SDK to a wasi-sdk install (see docs/35 §5.1)"; exit 1; }
	mkdir -p $(WASM_BUILD)/ir
	$(WASM_CC) $(WASM_CFLAGS) -Iinclude -S -emit-llvm $< -o $@

wasm32-wasi-ir: $(WASM_IR)

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

# ── x86_64-pc-windows-msvc ───────────────────────────────────────────────────
WIN_TRIPLE  := x86_64-pc-windows-msvc
WIN_BUILD   := build-$(WIN_TRIPLE)
WIN_CC      ?= clang
WIN_AR      ?= llvm-ar
WINE        ?=
# The CRT marks standard C functions (getenv, strerror, ...) deprecated in
# favour of its *_s variants; lyric-rt is portable C11 and uses the standard
# names.
WIN_CFLAGS  := --target=$(WIN_TRIPLE) -O2 -std=c11 -Wall -Wextra -Werror \
               -D_CRT_SECURE_NO_WARNINGS -D_CRT_NONSTDC_NO_WARNINGS
WIN_LDFLAGS := --target=$(WIN_TRIPLE) -fuse-ld=lld
# System import libraries the runtime calls into: CNG entropy (bcrypt), the
# UTF-16 command-line parser (shell32), the security descriptors of the
# child-process pipes (advapi32), Winsock (ws2_32), and Schannel with the
# certificate and key APIs (secur32, crypt32, ncrypt).  The compiler's native
# link step passes the same list.
WIN_LIBS    := -lbcrypt -lshell32 -ladvapi32 -lws2_32 -lsecur32 -lcrypt32 -lncrypt
WIN_SRCS    := src/lyric_rt.c src/lyric_string.c src/lyric_weak.c \
               src/lyric_win32.c src/lyric_collections.c src/lyric_async.c \
               src/lyric_fs_win32.c src/lyric_process_win32.c src/lyric_sock_win32.c \
               src/lyric_tls_win32.c src/lyric_parallel.c
WIN_OBJS    := $(WIN_SRCS:src/%.c=$(WIN_BUILD)/%.obj)
# lyric_rt_md.lib is the same runtime against the DLL C runtime, which an
# AddressSanitizer build links (Windows ASan works only with the DLL CRT);
# ordinary programs link lyric_rt.lib and the static CRT.
WIN_MD_OBJS := $(WIN_SRCS:src/%.c=$(WIN_BUILD)/md/%.obj)

$(WIN_BUILD)/%.obj: src/%.c include/lyric_rt.h src/lyric_win32_internal.h | $(WIN_BUILD)
	$(WIN_CC) $(WIN_CFLAGS) -Iinclude -c $< -o $@

$(WIN_BUILD)/md/%.obj: src/%.c include/lyric_rt.h src/lyric_win32_internal.h | $(WIN_BUILD)
	mkdir -p $(WIN_BUILD)/md
	$(WIN_CC) $(WIN_CFLAGS) -fms-runtime-lib=dll -Iinclude -c $< -o $@

$(WIN_BUILD)/lyric_string.obj $(WIN_BUILD)/md/lyric_string.obj: src/lyric_unicode_case_tables.inc src/lyric_unicode_category_tables.inc

# Recreated from scratch: `ar r` never drops a member, so an object removed
# from WIN_SRCS would otherwise linger in the archive.
$(WIN_BUILD)/lyric_rt.lib: $(WIN_OBJS)
	rm -f $@
	$(WIN_AR) rcs $@ $(WIN_OBJS)

$(WIN_BUILD)/lyric_rt_md.lib: $(WIN_MD_OBJS)
	rm -f $@
	$(WIN_AR) rcs $@ $(WIN_MD_OBJS)

$(WIN_BUILD):
	mkdir -p $(WIN_BUILD)

windows: $(WIN_BUILD)/lyric_rt.lib $(WIN_BUILD)/lyric_rt_md.lib

# The unit tests that need fork, signals, POSIX file modes or /bin/sh are
# compiled out under _WIN32; test/lyric_win32_test.c covers the Win32-only
# behaviour (UTF-16 paths, reparse points, console mode) and
# test/lyric_process_win32_test.c the Win32 process layer.
test-windows: $(WIN_BUILD)/lyric_rt.lib
	$(WIN_CC) $(WIN_CFLAGS) $(WIN_LDFLAGS) -Iinclude test/lyric_rt_test.c $(WIN_BUILD)/lyric_rt.lib $(WIN_LIBS) -o $(WIN_BUILD)/lyric_rt_test.exe
	$(WINE) $(WIN_BUILD)/lyric_rt_test.exe
	$(WIN_CC) $(WIN_CFLAGS) $(WIN_LDFLAGS) -Iinclude test/lyric_win32_test.c $(WIN_BUILD)/lyric_rt.lib $(WIN_LIBS) -o $(WIN_BUILD)/lyric_win32_test.exe
	$(WINE) $(WIN_BUILD)/lyric_win32_test.exe
	$(WIN_CC) $(WIN_CFLAGS) $(WIN_LDFLAGS) -Iinclude test/lyric_process_win32_test.c $(WIN_BUILD)/lyric_rt.lib $(WIN_LIBS) -o $(WIN_BUILD)/lyric_process_win32_test.exe
	$(WINE) $(WIN_BUILD)/lyric_process_win32_test.exe
	$(WIN_CC) $(WIN_CFLAGS) $(WIN_LDFLAGS) -Iinclude test/lyric_tls_test.c $(WIN_BUILD)/lyric_rt.lib $(WIN_LIBS) -o $(WIN_BUILD)/lyric_tls_test.exe
	$(WINE) $(WIN_BUILD)/lyric_tls_test.exe
	$(WIN_CC) $(WIN_CFLAGS) $(WIN_LDFLAGS) -Iinclude test/lyric_parallel_test.c $(WIN_BUILD)/lyric_rt.lib $(WIN_LIBS) -o $(WIN_BUILD)/lyric_parallel_test.exe
	$(WINE) $(WIN_BUILD)/lyric_parallel_test.exe
	LYRIC_THREADS=1 $(WINE) $(WIN_BUILD)/lyric_parallel_test.exe --serial
	LYRIC_THREADS=3 $(WINE) $(WIN_BUILD)/lyric_parallel_test.exe

clean:
	rm -rf $(BUILD)

clean-windows:
	rm -rf $(WIN_BUILD)

clean-wasm32-wasi:
	rm -rf $(WASM_BUILD)
