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
        src/lyric_posix.c src/lyric_collections.c src/lyric_async.c
OBJS := $(SRCS:src/%.c=$(BUILD)/%.o)

.PHONY: all test clean

all: $(BUILD)/lyric_rt.a

$(BUILD)/%.o: src/%.c include/lyric_rt.h | $(BUILD)
	$(CC) $(CFLAGS) -Iinclude -c $< -o $@

$(BUILD)/lyric_rt.a: $(OBJS)
	$(AR) rcs $@ $(OBJS)

$(BUILD):
	mkdir -p $(BUILD)

test: $(BUILD)/lyric_rt.a
	$(CC) $(CFLAGS) -Iinclude test/lyric_rt_test.c $(BUILD)/lyric_rt.a -lpthread -o $(BUILD)/lyric_rt_test
	$(BUILD)/lyric_rt_test

clean:
	rm -rf $(BUILD)
