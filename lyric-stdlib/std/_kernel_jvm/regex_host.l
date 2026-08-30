//! std/_kernel_jvm/regex_host.l — JVM kernel boundary for regex.
//!
//! Mirrors _kernel/regex_host.l for the JVM target: the same five-function
//! surface over java.util.regex.Pattern / Matcher, as pure Lyric over the
//! JVM auto-FFI.  The previous version routed isMatch / matchOne / replace /
//! compileWithTimeout through a phantom `lyric.stdlib.jvm.RegexHost` class
//! that never existed at runtime, which left those operations non-functional
//! on this target (docs/59 F-1c).
//!
//! **ReDoS timeout enforcement (#330 / #1103 / #6576):** `java.util.regex.Pattern`
//! carries no timeout mechanism of its own (unlike the BCL `Regex` object,
//! which bakes a `matchTimeout` into the compiled pattern via its 3-arg
//! constructor).  This kernel closes that gap with the standard
//! daemon-thread-race technique the issue asked for: every match operation
//! (`hostIsMatch` / `hostMatchOne` / `hostReplace`) runs the actual
//! `Matcher` call on a fresh background thread while the calling thread
//! blocks on `Thread.join(timeoutMs)` — a bounded wait, unlike
//! `Future.get()`. `Regex` is therefore no longer a bare `extern type`
//! alias for `Pattern`; it is a small Lyric record pairing the compiled
//! `Pattern` with the timeout (milliseconds) baked in by
//! `hostCompile`/`hostCompileWithTimeout` — the JVM-side equivalent of the
//! BCL 3-arg constructor's embedded `matchTimeout`. `Match` is unchanged
//! (still the real `java.util.regex.Matcher`, per the module's existing
//! Phase 6 group-access note below).
//!
//! Why a raw `java.lang.Thread`, not `ExecutorService`/`Future.get(timeout,
//! TimeUnit)` or the `scope`/`spawn`/`await` language keywords (prior art
//! surveyed per the issue's own guidance):
//!   - `Future.get(long, TimeUnit)` needs a `TimeUnit` argument; the JVM
//!     auto-FFI method resolver skips enum-typed parameters entirely
//!     (`_kernel_jvm/process_capture_host.l`'s `Process.waitFor(long,
//!     TimeUnit)` note documents the same gap), so that overload is
//!     unreachable from plain Lyric regardless of the surrounding API.
//!   - `scope { }` / `spawn` / `await` compile to real JDK 21
//!     `StructuredTaskScope`, whose `close()` blocks until every spawned
//!     subtask's THREAD actually terminates — even after a `shutdown()`
//!     best-effort interrupt (`_kernel_jvm/task.l`'s module header
//!     documents choosing these keywords specifically because there is no
//!     other closure-to-concurrent-execution bridge from plain Lyric, but
//!     structured concurrency's whole point is "no orphaned threads survive
//!     scope exit" — exactly the leak a ReDoS timeout needs to accept, so
//!     it cannot give a bounded wait against non-interruptible work).
//!   - A raw, unstructured `Thread.join(millis)` DOES return after `millis`
//!     regardless of whether the thread has finished — the only primitive
//!     reachable from pure Lyric that provides a genuine bounded wait here.
//!   - Documented tradeoff, same as every daemon-thread-race timeout
//!     technique on the JVM: `java.util.regex` is not interruptible (no
//!     backtracking checkpoint observes `Thread.interrupt()`), so a timed-
//!     out match is *abandoned* running rather than stopped — the caller is
//!     unblocked within the deadline (the actual ReDoS protection: an
//!     attacker can no longer tie up the calling thread indefinitely), but
//!     the abandoned background thread may keep burning CPU until it
//!     finishes naturally or the JVM exits. A fully leak-free fix needs an
//!     interruptible `CharSequence` wrapper around the match input (its
//!     `charAt`/`length` observing the deadline and throwing) so the
//!     backtracking loop itself notices promptly — a real further
//!     improvement, but out of scope here: the issue asked specifically for
//!     the daemon-thread shim, and this closes the actual vulnerability
//!     (unbounded blocking) that #330/#1103 track.
//!
//! **Virtual threads + a concurrency cap (#6576):** the background thread
//! is now started via `Thread.startVirtualThread(Runnable)` (GA since JDK
//! 21, no preview flag) instead of `new Thread(...)`.  Every match/replace
//! call pays a thread spin-up on the timeout-racing path — with a platform
//! `Thread` that's a real OS-thread-creation cost on every single call,
//! even the overwhelming common case of a benign, fast-matching pattern.
//! A virtual thread's spin-up is orders of magnitude cheaper (a
//! `Continuation` object, not an OS thread), which is what actually closes
//! the throughput gap for that common case; `Thread.join(millis)` is
//! supported identically on a virtual `Thread`, so the bounded-wait design
//! above is unchanged.
//!
//! Carrier-pinning was investigated, not assumed away.  JEP 444's "pinning"
//! specifically means a virtual thread parking *inside* a `synchronized`
//! block or a native frame, which blocks its carrier from being freed for
//! another virtual thread even while the operation is logically blocked;
//! `Pattern.matcher(...).find()`/`.replaceAll(...)` take no monitor and
//! make no native call, so a regex match is never "pinned" in that formal
//! sense.  There is a *related* but distinct risk that pinning does not
//! cover: virtual-thread scheduling is cooperative, not preemptive, for
//! CPU-bound work that never reaches a blocking op — a virtual thread
//! doing tight, non-yielding computation (which catastrophic backtracking
//! is) holds its carrier for the computation's entire duration with no
//! JVM-level time-slicing, whereas the platform-thread design got real OS
//! preemption across however many abandoned threads had piled up. Once
//! live abandoned matches reach the carrier pool's parallelism (default
//! `Runtime.availableProcessors()`, tunable only via the
//! `jdk.virtualThreadScheduler.parallelism` system property — the JDK
//! exposes no public per-call-site custom-scheduler API in 21), every
//! carrier is monopolized and unrelated virtual-thread work sharing that
//! pool (e.g. other request handlers) queues behind it until each
//! abandoned match finishes naturally. A concurrency cap cannot prevent
//! that momentary saturation once it reaches the carrier count — no
//! achievable cap value fixes that without either an interruptible match
//! (the CharSequence wrapper noted above, not yet built) or a dedicated
//! non-shared carrier pool (not exposed by the public JDK 21 API). What a
//! cap *does* fix is the other half of the original concern: unbounded
//! accumulation of live abandoned matches over an app's lifetime under
//! sustained attack traffic, each one a permanently-running background
//! computation that never gets reclaimed. `matchSemaphore` (below) bounds
//! that to `maxConcurrentMatches` via non-blocking `tryAcquire()` —
//! rejected immediately (see `saturationMessage`) rather than queued, so a
//! caller already inside its own bounded-wait contract never blocks
//! waiting for a permit held by an abandoned match that may never release
//! it. The permit is released by the background thread itself once its
//! `action` call returns (success or fault) — for a timed-out match that
//! is only once the abandoned computation finally finishes on its own,
//! matching the intended "cap the *outstanding* set, timed-out or not"
//! semantics. This closes #6576(b) (unbounded thread/permit accumulation);
//! the momentary carrier-pool-saturation risk from #6576's carrier-pinning
//! note is real but not something a per-call cap can eliminate, and is
//! judged acceptable for this kernel's threat model: it degrades shared
//! virtual-thread throughput during an active attack, it does not grow
//! unboundedly, and defending against sustained attack traffic in the
//! first place (rate limiting, WAF) is out of scope for a regex kernel.
//!
//! **Permit release is `defer`-guaranteed, not a post-`try` statement
//! (#6711):** `raceWithDeadline`'s background-thread lambda releases
//! `matchSemaphore` via `defer { matchSemaphore.release() }`, registered
//! before the `try { action() } catch Bug as b { ... }` that runs the
//! actual match — not as a plain statement placed after that block. A
//! plain post-`try` statement only runs when the `try`/`catch` completes
//! normally; anything that unwinds past the `catch` arm entirely would
//! skip it and leak the permit forever (each occurrence permanently
//! shrinking `maxConcurrentMatches` by one). `catch Bug` on THIS target
//! lowers to `catch (java.lang.Throwable)` (`Jvm.Codegen`'s catch-class
//! resolution, `codegen/05_stmts.l`) — the widest possible JVM catch,
//! already covering ordinary exceptions and JVM `Error`s alike (a real
//! `StackOverflowError` from a pathologically deep pattern was directly
//! verified to still be caught by it) — so no ordinary fault actually
//! escapes the existing `catch Bug` arm on this target today; `defer`
//! is defense in depth against that invariant ever narrowing, not a fix
//! for an exploitable escape verified to exist right now. It costs
//! nothing to get right: `regex_jvm_semaphore_leak_self_test.l` pins a
//! sustained real fault path (an out-of-range `$n` group reference in a
//! replacement string, which throws `IndexOutOfBoundsException` from
//! `Matcher.replaceAll` inside the raced closure, not a pattern-compile-
//! time error) never exhausts `matchSemaphore` across many repeated
//! calls. `defer`-inside-a-closure-body was itself verified against a
//! real JVM build before landing (mirroring this file's own captured-
//! `var`-in-`catch` note below): combined with a captured `AtomicBoolean`
//! *and* an `AtomicReference` *and* a captured closure parameter (this
//! module's exact shape) it lowers correctly; a simpler synthetic repro
//! with a different capture/call shape was found to trip an unrelated,
//! pre-existing `VerifyError: Operand stack overflow` in the JVM
//! `defer`+`try`/`catch`-inside-a-closure `maxStack` calculation — not
//! reachable from this module's actual shape, but real, tracked as #6714.
//!
//! Replacement-string semantics: Matcher.replaceAll treats `$n` group
//! references the same way .NET substitutions do; Java additionally
//! treats backslash as an escape in the replacement.
//!
//! Functions are prefixed `host*` following the Std.HttpHost convention
//! to prevent name-shadowing recursion when Std.Regex (std/regex.l)
//! calls RxHost.hostCompile(...) etc.
//!
//! The public Lyric API lives in std/regex.l (Std.Regex).  Import
//! Std.RegexHost only in stdlib internals that need the raw JVM types.
@axiom("java.util.regex.Pattern and java.util.regex.Matcher conform to their documented JVM contracts")
package Std.RegexHost

import Std.Core

// java.util.regex.Pattern — compiled regex (existing JDK type).
// java.util.regex.Matcher — stateful match cursor (existing JDK type).
extern type JPattern = "java.util.regex.Pattern"

extern type Match = "java.util.regex.Matcher"

extern type JThread = "java.lang.Thread"

extern type JRuntime = "java.lang.Runtime"

extern type JSemaphore = "java.util.concurrent.Semaphore"

// ─── Compilation ─────────────────────────────────────────────────────────────
// Default compile: routes to java.util.regex.Pattern.compile(String).
// Throws PatternSyntaxException (a Bug to Lyric callers) on invalid syntax.
@externTarget("java.util.regex.Pattern.compile")
func rawCompile(pattern: in String): JPattern = ()

/// A compiled pattern with its match timeout baked in (milliseconds) — the
/// JVM-side equivalent of the BCL 3-arg `Regex(pattern, options,
/// matchTimeout)` constructor's embedded deadline. Opaque to every consumer
/// (`Std.Regex` / `Std.RegexSafe` only ever pass this back through, never
/// inspect it), so this record shape is a JVM-only internal — the `.NET`
/// kernel keeps `Regex` as a bare `Pattern`-equivalent alias.
pub record Regex {
  pattern: JPattern
  timeoutMs: Long
}

// Matches _kernel/regex_host.l's default 1-second match timeout.
val defaultTimeoutMs: Long = 1000i64

/// Compile a regex pattern with the default 1-second match timeout.
pub func hostCompile(pattern: in String): Regex {
  Regex(pattern = rawCompile(pattern), timeoutMs = defaultTimeoutMs)
}

/// Compile with a custom timeout in seconds.  Enforced on every match
/// operation via the daemon-thread race (see module header).
pub func hostCompileWithTimeout(pattern: in String, seconds: in Double): Regex
  requires: seconds > 0.0
{
  Regex(pattern = rawCompile(pattern), timeoutMs = secondsToDeadlineMs(seconds))
}

// `seconds > 0.0` is enforced by `requires:` above, but a very small
// fractional-second value (e.g. 0.0005) truncates to 0 milliseconds via
// `.toLong()` — and `Thread.join(0)` means "wait forever" per its Javadoc
// (0 is the sentinel for "no timeout"), which would silently turn a tiny
// requested timeout into an unbounded block, the exact bug this module
// exists to prevent.  Clamp to a 1ms floor.
func secondsToDeadlineMs(seconds: in Double): Long {
  val ms = (seconds * 1000.0).toLong()
  if ms < 1i64 {
    1i64
  } else {
    ms
  }
}

// ─── Daemon-thread deadline race ─────────────────────────────────────────────
// Outcome of racing `action` against `timeoutMs` on a background thread (see
// module header for why this shape, not Future/ExecutorService/scope).
// `saturated` short-circuits the other two fields (no thread was even
// started — see `matchSemaphore` below); otherwise exactly one of
// `timedOut` / (not timedOut) applies, and when not timed out `faulted`
// distinguishes "action ran to completion successfully" (the caller's own
// captured `var`s hold the real result) from "action threw" (`faultMessage`
// carries the original exception's message, re-panicked by the caller so
// unrelated bugs — e.g. a JVM `StackOverflowError` from a pathologically
// deep pattern — surface as themselves, not silently as a stale/default
// result).
record RaceOutcome {
  timedOut: Bool
  faulted: Bool
  faultMessage: String
  saturated: Bool
}

// Fault state shared between the background thread and the joining thread.
// A plain captured `var` mutated from inside a `catch` arm INSIDE a closure
// hits a real, pre-existing JVM codegen bug (verified in isolation: a
// closure body shaped `try { ... } catch Bug as b { <captured var> = ...
// }` fails class verification with "Operand stack overflow" — a `maxStack`
// miscalculation specific to that exact combination, unrelated to this
// module) — so this uses `Std.Task`'s established `runGuardedJvm` idiom
// instead: JDK atomics mutated via method calls, never a direct Lyric
// `var` assignment inside the catch arm.
extern type JAtomicBoolean = "java.util.concurrent.atomic.AtomicBoolean"

extern type JAtomicReference = "java.util.concurrent.atomic.AtomicReference"

// Caps the number of concurrently-outstanding match operations (timed-out
// ones included) — see the module header's "Virtual threads + a
// concurrency cap" section for why this exists and what it does/doesn't
// protect against.  Scaled off the carrier pool's own sizing signal
// (`availableProcessors()`, the same default the JVM's virtual-thread
// scheduler uses) with headroom for legitimate bursty concurrent load,
// which — unlike an abandoned ReDoS match — holds its permit only for the
// real match duration (microseconds for a benign pattern) before
// releasing it; floored so a small-core CI/container environment still
// gets a workable cap.
func computeMaxConcurrentMatches(): Int {
  val cores = JRuntime.getRuntime().availableProcessors()
  val scaled = cores * 16
  if scaled < 64 {
    64
  } else {
    scaled
  }
}

val maxConcurrentMatches: Int = computeMaxConcurrentMatches()

// One process-wide permit pool shared by every `Regex` value on this
// target — matches the fact that the underlying risk (unbounded
// background-thread accumulation) is a process-wide resource, not a
// per-pattern one.
val matchSemaphore: JSemaphore = JSemaphore.new(maxConcurrentMatches)

func raceWithDeadline(action: in () -> Unit, timeoutMs: in Long): RaceOutcome {
  if matchSemaphore.tryAcquire() {
    val hasFault: JAtomicBoolean = JAtomicBoolean.new(false)
    val faultMessage: JAtomicReference = JAtomicReference.new("")
    // The lambda literal is passed directly as the call argument (not
    // bound to a `val` first): `Jvm.Codegen`'s Lyric-closure-to-
    // functional-interface SAM bridging (`emitFfiCoerce`,
    // `codegen/04_calls.l`) only fires when the argument expression's own
    // static type is the package's `Lyric$Lambda` interface — a `val f: ()
    // -> Unit = { -> ... }` local's declared function-type annotation
    // erases differently, so passing `f` by name skipped the bridge and
    // handed the SAM parameter the raw (non-`Runnable`) closure object,
    // verified by direct experiment (`IncompatibleClassChangeError: ...
    // does not implement the requested interface java.lang.Runnable`).
    // `matchSemaphore.release()` runs inside the background thread itself,
    // after `action` returns — for a timed-out match that only happens
    // once the abandoned computation finally finishes on its own, which is
    // the intended "cap the outstanding set, timed-out or not" semantics
    // (module header).  Virtual threads are always daemon threads (a JVM
    // invariant — `setDaemon(false)` on one throws), so no explicit
    // `setDaemon` call is needed here.
    val t = JThread.startVirtualThread(
      { ->
        defer {
          matchSemaphore.release()
        }
        try {
          action()
        } catch Bug as b {
          hasFault.set(true)
          faultMessage.set(b.message)
        };
        ()
      }
    )
    t.join(timeoutMs)
    if t.isAlive() {
      RaceOutcome(timedOut = true, faulted = false, faultMessage = "", saturated = false)
    } else if hasFault.get() {
      val msg: String = faultMessage.get()
      RaceOutcome(timedOut = false, faulted = true, faultMessage = msg, saturated = false)
    } else {
      RaceOutcome(timedOut = false, faulted = false, faultMessage = "", saturated = false)
    }
  } else {
    RaceOutcome(timedOut = false, faulted = false, faultMessage = "", saturated = true)
  }
}

// Shared deadline-exceeded message: MUST contain the literal substring
// "time-out" — `Std.Regex.isTimeout` / `Std.RegexSafe`'s classifiers scan
// for that exact phrase to route a caught `Bug` to `TimedOut` rather than
// `InvalidPattern`/`RegexBug` (see std/regex.l's `isTimeout`).
func timeoutMessage(op: in String, timeoutMs: in Long): String {
  op + " exceeded its configured time-out of " + timeoutMs.toString() + "ms"
}

// Capacity-rejection message.  Deliberately ALSO contains "time-out" (see
// `timeoutMessage` above): from the caller's perspective the contract is
// "this operation is bounded," and rejecting immediately because the
// system-wide in-flight cap (`maxConcurrentMatches`) is already saturated
// is a different cause but the same observable shape as a timeout — the
// caller was not, and will not be, blocked waiting for this match. Callers
// that need to tell the two apart can do so on the message text.
func saturationMessage(op: in String): String {
  op + " was rejected before it could start: its bounded time-out contract could not be honored because " +
    maxConcurrentMatches.toString() +
    " regex match operations are already in flight (system-wide cap)"
}

// ─── Match operations ────────────────────────────────────────────────────────
/// True when `input` contains at least one match: Pattern.matcher + find(),
/// raced against `r`'s compiled-in timeout.
pub func hostIsMatch(r: in Regex, input: in String): Bool {
  var result = false
  val outcome = raceWithDeadline({ -> result = matchFind(r.pattern, input) }, r.timeoutMs)
  if outcome.saturated {
    panic(saturationMessage("regex match"))
  } else if outcome.timedOut {
    panic(timeoutMessage("regex match", r.timeoutMs))
  } else if outcome.faulted {
    panic(outcome.faultMessage)
  } else {
    result
  }
}

func matchFind(p: in JPattern, input: in String): Bool {
  val m = p.matcher(input)
  m.find()
}

/// First-match cursor: Pattern.matcher advanced by one find(), so
/// group()/start()/end() on the returned Matcher describe the first match
/// (mirroring .NET's Regex.Match, whose result is already positioned).
/// Raced against `r`'s compiled-in timeout.
pub func hostMatchOne(r: in Regex, input: in String): Match {
  val m = r.pattern.matcher(input)
  val outcome = raceWithDeadline({ -> advanceToFirstMatch(m) }, r.timeoutMs)
  if outcome.saturated {
    panic(saturationMessage("regex match-one"))
  } else if outcome.timedOut {
    panic(timeoutMessage("regex match-one", r.timeoutMs))
  } else if outcome.faulted {
    panic(outcome.faultMessage)
  } else {
    m
  }
}

// The find() result is deliberately consumed by the tail-position
// Bool-to-Unit coercion (the same pattern as process_host.l hostWait —
// a non-tail discarded auto-FFI call would be elided entirely, #5379);
// "no match found" is observable on the Matcher itself.
func advanceToFirstMatch(m: in Match): Unit {
  m.find()
}

/// Replace every match of `r` in `input`: Pattern.matcher + replaceAll,
/// raced against `r`'s compiled-in timeout.
pub func hostReplace(r: in Regex, input: in String, replacement: in String): String {
  var result = ""
  val outcome = raceWithDeadline({ -> result = doReplace(r.pattern, input, replacement) }, r.timeoutMs)
  if outcome.saturated {
    panic(saturationMessage("regex replace"))
  } else if outcome.timedOut {
    panic(timeoutMessage("regex replace", r.timeoutMs))
  } else if outcome.faulted {
    panic(outcome.faultMessage)
  } else {
    result
  }
}

func doReplace(p: in JPattern, input: in String, replacement: in String): String {
  val m = p.matcher(input)
  m.replaceAll(replacement)
}

// ─── Match inspection ────────────────────────────────────────────────────────
//
// After hostMatchOne(r, input), the returned java.util.regex.Matcher is
// positioned on the first match (when one exists).  Group access
// (Matcher.group(int)) is a Phase 6 follow-up.
