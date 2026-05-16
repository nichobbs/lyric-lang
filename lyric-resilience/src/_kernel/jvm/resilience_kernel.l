/// Resilience.Kernel.Jvm — JVM resilience extern boundary.
///
/// JVM implementation of the same contract as Resilience.Kernel.Net.
/// Circuit state uses ConcurrentHashMap; sleep uses Thread.sleep.
///
/// Only active when compiled with feature = "jvm" (Phase 6).

@cfg(feature = "jvm")
package Resilience.Kernel.Jvm

import Std.Core

@axiom("java.lang.Thread.sleep for retry backoff")
extern package java.lang {
  pub func sleepMs(ms: Int): Unit
    requires: ms >= 0
}

@axiom("lyric.resilience.CircuitStore backed by ConcurrentHashMap")
extern package lyric.resilience {
  pub func circuitIsOpen(name: String, cooldownMs: Int): Bool
    requires: name.length > 0
    requires: cooldownMs > 0

  pub func circuitRecordSuccess(name: String): Unit
    requires: name.length > 0

  pub func circuitRecordFailure(name: String, failureThreshold: Int): Unit
    requires: name.length > 0
    requires: failureThreshold > 0
}
