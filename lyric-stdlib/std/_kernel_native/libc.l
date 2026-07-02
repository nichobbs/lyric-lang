//! std/_kernel_native/libc.l — raw libc boundary for the native target
//! (D-N-007).  Bare C symbols behind `extern func`; the safe Lyric
//! wrappers over these live in the per-module `_kernel_native/*_host.l`
//! files and the public `Std.*` surface — application code should never
//! import this package directly.
//!
//! `NativePtr[T]` parameters make these declarations unsafe by
//! construction; they are only legal inside `_kernel_native/` packages
//! (mode-checker rule N0100, docs/01 FFI section).
@axiom("POSIX / C99 libc functions conform to their documented contracts")
package Std.LibcHost

extern func write(fd: Int, buf: NativePtr[Byte], n: Long): Long = "write"

extern func read(fd: Int, buf: NativePtr[Byte], n: Long): Long = "read"

extern func openFile(path: NativePtr[Byte], flags: Int, mode: Int): Int = "open"

extern func closeFd(fd: Int): Int = "close"

extern func unlink(path: NativePtr[Byte]): Int = "unlink"

extern func mkdir(path: NativePtr[Byte], mode: Int): Int = "mkdir"

extern func rmdir(path: NativePtr[Byte]): Int = "rmdir"

extern func strlen(s: NativePtr[Byte]): Long = "strlen"

extern func malloc(n: Long): NativePtr[Byte] = "malloc"

extern func free(ptr: NativePtr[Byte]): Unit = "free"

extern func exitProcess(code: Int): Unit = "exit"

// open(2) flag values are platform-specific (O_CREAT differs between
// Linux and macOS); lyric-rt exposes them as functions so no platform
// table is hardcoded here (native/plan/07-stdlib-port.md).
extern func oRdonly(): Int = "lyric_o_rdonly"

extern func oWronly(): Int = "lyric_o_wronly"

extern func oRdwr(): Int = "lyric_o_rdwr"

extern func oCreat(): Int = "lyric_o_creat"

extern func oTrunc(): Int = "lyric_o_trunc"

extern func oAppend(): Int = "lyric_o_append"

extern func fileSize(path: NativePtr[Byte]): Long = "lyric_file_size"

// LyricString <-> C-string bridging (lyric-rt).
extern func stringToCString(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func cstringFree(p: NativePtr[Byte]): Unit = "lyric_cstring_free"
