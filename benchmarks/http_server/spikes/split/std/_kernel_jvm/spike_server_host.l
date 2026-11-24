//! SPIKE (docs/73 S0 spike a), not shipped: JVM kernel of the `Std.SpikeServerHost` seam.
@axiom("java.lang.Thread.startVirtualThread and java.util.concurrent.Semaphore operations conform to their documented JVM contracts")
@io
package Std.SpikeServerHost

import Std.Core

extern type JThread = "java.lang.Thread"

extern type JRunnable = "java.lang.Runnable"

pub extern type Sem = "java.util.concurrent.Semaphore"

record SpawnJob {
  work: () -> Unit
}

impl JRunnable for SpawnJob {
  func run(): Unit {
    self.work()
  }
}

pub func newSem(initialCount: in Int): Sem {
  Sem.new(initialCount)
}

pub func semWait(s: in Sem): Unit {
  s.acquire()
}

pub func semPost(s: in Sem): Unit {
  s.release()
}

pub func startTask(work: in () -> Unit): Unit {
  val t: JThread = JThread.startVirtualThread(SpawnJob(work = work));
  ()
}
