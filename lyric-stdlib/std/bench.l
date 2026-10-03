//! Std.Bench - measurements for benchmarks.
//!
//! `lyric bench` reports the bytes each benchmark allocates per run from
//! `allocatedBytes`; a program can call it directly around code whose
//! allocation it wants to check.
@io
package Std.Bench

import Std.Core
import Std.BenchHost

/// The bytes the current thread has allocated on the heap since it started.
/// The difference between two readings is what the code between them
/// allocated: on dotnet the managed heap (`GC.GetAllocatedBytesForCurrentThread`),
/// on the JVM the thread's allocation counter
/// (`ThreadMXBean.getCurrentThreadAllocatedBytes`), and on native every object,
/// collection and string the runtime allocated (`lyric_alloc`; the C buffers
/// its file, process, socket and TLS code allocates are not counted).  Values the
/// native backend stores inline (by-value records, inline arrays) allocate
/// nothing.
@experimental
pub func allocatedBytes(): Long = hostAllocatedBytes()
