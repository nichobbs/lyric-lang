//! std/_kernel_jvm/bench_host.l - host boundary for `Std.Bench` on the JVM.
//!
//! Internal: only `Std.Bench` imports this.
@axiom("com.sun.management.ThreadMXBean.getCurrentThreadAllocatedBytes conforms to its documented JDK contract")
@io
package Std.BenchHost

import Std.Core

extern type JManagement = "java.lang.management.ManagementFactory"

extern type JThreadBean = "com.sun.management.ThreadMXBean"

/// Bytes allocated on the heap by the current thread.  HotSpot's thread
/// bean implements `com.sun.management.ThreadMXBean`, which carries the
/// per-thread allocation counter.
pub func hostAllocatedBytes(): Long {
  val bean: JThreadBean = JManagement.getThreadMXBean()
  bean.getCurrentThreadAllocatedBytes()
}
