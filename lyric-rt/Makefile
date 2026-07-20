# lyric-rt — the Lyric native runtime static library.
#
#   make            -> build/lyric_rt.a
#   make test       -> build and run the C unit tests
#   make clean
#
# CC defaults to clang (the toolchain the native backend drives; D-N-001)
# but any C11 compiler works.

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

.PHONY: all test test-asan clean

all: $(BUILD)/lyric_rt.a

$(BUILD)/%.o: src/%.c include/lyric_rt.h | $(BUILD)
	$(CC) $(CFLAGS) -Iinclude -c $< -o $@

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

clean:
	rm -rf $(BUILD)
