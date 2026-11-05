//! std/_kernel_native/io_wait.l — waiting for a descriptor to become ready
//! (the async I/O reactor, #8494, D405).
//!
//! `waitFd` waits until a socket (or, on POSIX, any pollable descriptor) is
//! ready to read or write, or a timeout passes.  Called from a synchronous
//! function it blocks the thread in `poll` (`WSAPoll` on Windows).  Called
//! from an `async func` on `--target native` it is the reactor leaf: the code
//! generator lowers it to `lyric_async_wait_fd` and a suspend point, so only
//! the calling task waits and the scheduler thread runs other tasks
//! meanwhile, the way `Std.Time.sleepMillis` parks a task on the timer list.
//!
//! The kernel socket functions use it for their asynchronous twins
//! (`_kernel_native/tcp_host.l`); it is not a public API.
package Std.IoWait

extern func rtFdWait(fd: Long, events: Int, timeoutMs: Long): Int = "lyric_fd_wait"

extern func rtFdWait2(fd: Long, events: Int, fd2: Long, events2: Int, timeoutMs: Long): Int = "lyric_fd_wait2"

/// Ready to read (or a pending connection on a listening socket).
pub val ioRead: Int = 1

/// Ready to write.
pub val ioWrite: Int = 2

/// An error or hang-up, which the next read or write reports.
pub val ioError: Int = 4

/// How far `waitFd2` shifts the second descriptor's bits.
pub val ioSecondShift: Int = 4

/// Waits until `fd` is ready for `events` (`ioRead`, `ioWrite` or both) or
/// `timeoutMs` passes (negative: no timeout).  Returns the ready bits, with
/// `ioError` for an error or hang-up, or 0 on timeout.
pub func waitFd(fd: in Int, events: in Int, timeoutMs: in Int): Int {
  rtFdWait(fd.toLong(), events, timeoutMs.toLong())
}

/// `waitFd` over two descriptors: returns when either is ready, `fd2`'s bits
/// shifted left by `ioSecondShift`.
pub func waitFd2(fd: in Int, events: in Int, fd2: in Int, events2: in Int, timeoutMs: in Int): Int {
  rtFdWait2(fd.toLong(), events, fd2.toLong(), events2, timeoutMs.toLong())
}
