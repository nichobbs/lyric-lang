//! SPIKE (docs/73 S0 spike a), not shipped: native kernel of the `Std.SpikeServerHost` seam.
//! Spawn goes through `Std.Task` (a detached scope per startTask) rather than a raw `pthread_create`, because
//! the spike is about package loading and shared-Lyric constructs, not about the closure-retain
//! discipline of `_kernel_native/http_server.l`.
package Std.SpikeServerHost

import Std.Core
import Std.Task as Task

extern func rtMallocRaw(n: Long): NativePtr[Byte] = "lyric_malloc_raw"

extern func rtPtrToLong(p: NativePtr[Byte]): Long = "lyric_ptr_to_long"

extern func rtLongToPtr(v: Long): NativePtr[Byte] = "lyric_long_to_ptr"

extern func rtSemSize(): Int = "lyric_sem_size"

extern func rtSemInitRaw(s: NativePtr[Byte], initial: Int): Unit = "lyric_sem_init"

extern func rtSemWaitRaw(s: NativePtr[Byte]): Unit = "lyric_sem_wait"

extern func rtSemPostRaw(s: NativePtr[Byte]): Unit = "lyric_sem_post"

pub ref record Sem {
  handle: Long
}

pub func newSem(initialCount: in Int): Sem {
  val h = rtPtrToLong(rtMallocRaw(rtSemSize().toLong()))
  rtSemInitRaw(rtLongToPtr(h), initialCount)
  Sem(handle = h)
}

pub func semWait(s: in Sem): Unit {
  rtSemWaitRaw(rtLongToPtr(s.handle))
}

pub func semPost(s: in Sem): Unit {
  rtSemPostRaw(rtLongToPtr(s.handle))
}

pub func startTask(work: in () -> Unit): Unit {
  Task.scopeSpawn(Task.makeScope(), work)
}
