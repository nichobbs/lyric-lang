//! SPIKE (docs/73 S0 spike a), not shipped: dotnet kernel of the `Std.SpikeServerHost` seam.
@axiom("System.Threading.Tasks.Task.Run and System.Threading.SemaphoreSlim operations conform to their documented .NET contracts")
@io
package Std.SpikeServerHost

import Std.Core

@sendable
extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@sendable
pub extern type Sem = "System.Threading.SemaphoreSlim"

@externTarget("System.Threading.SemaphoreSlim..ctor")
pub func newSem(initialCount: in Int): Sem = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Wait")
pub func semWait(s: in Sem): Unit = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Release")
func semRelease(s: in Sem): Int = ()

pub func semPost(s: in Sem): Unit {
  val _ = semRelease(s);
  ()
}

pub func startTask(work: in () -> Unit): Unit {
  val _ = taskRun(work);
  ()
}
