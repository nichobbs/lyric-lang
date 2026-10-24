/* lyric_win32_internal.h — helpers shared by the Win32 halves of lyric-rt
 * (lyric_win32.c, lyric_fs_win32.c; docs/67 G9).  Not part of the public
 * runtime surface in lyric_rt.h.
 *
 * Lyric strings are UTF-8 and Win32's narrow ("A") entry points use the ANSI
 * code page, so every path, environment variable and command-line argument
 * crosses the boundary through the wide ("W") entry points, converted here.
 */
#ifndef LYRIC_WIN32_INTERNAL_H
#define LYRIC_WIN32_INTERNAL_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <stddef.h>
#include <stdint.h>

/* A freshly malloc'd NUL-terminated UTF-16 copy of the NUL-terminated UTF-8
 * string `s`, or NULL when `s` is not valid UTF-8 or memory runs out. */
wchar_t* lyric_win32_wide(const char* s);

/* lyric_win32_wide for a file-system path: a path whose full form is long
 * enough to meet the MAX_PATH family of limits is returned normalised
 * (GetFullPathNameW) with the extended-length prefix (\\?\, or \\?\UNC\
 * for a share), so files and directories with long paths work whether or
 * not the system enables long paths.  Shorter paths are returned as given,
 * so device names (NUL, CON) and relative paths keep their usual meaning.
 * NULL when `s` is not valid UTF-8 or memory runs out. */
wchar_t* lyric_win32_path(const char* s);

/* A freshly malloc'd NUL-terminated UTF-8 copy of the first `n` UTF-16 units
 * of `w` (n < 0: up to its NUL), writing the byte length (excluding the NUL)
 * through *out_len when it is non-NULL.  Unpaired surrogates become U+FFFD.
 * NULL when memory runs out. */
char* lyric_win32_utf8(const wchar_t* w, int64_t n, int64_t* out_len);

/* The errno value closest to the Win32 error code `err` (EIO when none is). */
int lyric_win32_errno(DWORD err);

/* The system message for Win32, Winsock or SSPI status `code`, as UTF-8
 * followed by the code, in `out` (truncated to `cap`). */
void lyric_win32_message(DWORD code, char* out, size_t cap);

/* The socket and TLS seam's thread-local diagnostic (lyric_tls_last_error),
 * set printf-style; defined in lyric_sock_win32.c. */
void lyric_net_set_err(const char* fmt, ...);

/* True when Winsock error `wsa_error` is a socket timeout
 * (lyric_sock_set_timeouts). */
int lyric_win32_sock_timed_out(int wsa_error);

/* recv() on socket `s` (a SOCKET) that lyric_sock_shutdown on the same socket
 * always ends: 0 means end of stream or shut down, -1 an error, with
 * WSAETIMEDOUT when SO_RCVTIMEO elapses.  Defined in lyric_sock_win32.c. */
int lyric_win32_sock_recv(uintptr_t s, char* buf, int len);

/* Nanoseconds since the Unix epoch of a FILETIME (100 ns ticks since
 * 1601-01-01). */
int64_t lyric_win32_filetime_to_unix_nanos(FILETIME ft);

#endif
