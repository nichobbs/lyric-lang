//! Resilience.Kernel.Jvm — JVM resilience extern boundary.
//!
//! JVM implementation of the same contract as Resilience.Kernel.Net.
//! Circuit state uses ConcurrentHashMap; sleep uses Thread.sleep.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
@cfg(feature = "jvm")
package Resilience.Kernel.Jvm

import Std.Core

@axiom("java.lang.Thread.sleep for retry backoff")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
  = ()

@axiom("lyric.resilience.CircuitStore backed by ConcurrentHashMap")
pub func circuitIsOpen(name: in String, cooldownMs: in Int): Bool
  requires: name.length > 0
  requires: cooldownMs > 0
  = false

@axiom("lyric.resilience.CircuitStore backed by ConcurrentHashMap")
pub func circuitRecordSuccess(name: in String): Unit
  requires: name.length > 0
  = ()

@axiom("lyric.resilience.CircuitStore backed by ConcurrentHashMap")
pub func circuitRecordFailure(name: in String, failureThreshold: in Int): Unit
  requires: name.length > 0
  requires: failureThreshold > 0
  = ()
