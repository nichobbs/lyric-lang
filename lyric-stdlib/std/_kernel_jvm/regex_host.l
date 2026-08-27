//! std/_kernel_jvm/regex_host.l — JVM kernel boundary for regex.
//!
//! Mirrors _kernel/regex_host.l for the JVM target: the same five-function
//! surface over java.util.regex.Pattern / Matcher, as pure Lyric over the
//! JVM auto-FFI.  The previous version routed isMatch / matchOne / replace /
//! compileWithTimeout through a phantom `lyric.stdlib.jvm.RegexHost` class
//! that never existed at runtime, which left those operations non-functional
//! on this target (docs/59 F-1c).
//!
//! **ReDoS timeout enforcement (#330 / #1103):** `java.util.regex.Pattern`
//! carries no timeout mechanism of its own (unlike the BCL `Regex` object,
//! which bakes a `matchTimeout` into the compiled pattern via its 3-arg
//! constructor).  This kernel closes that gap with the standard
//! daemon-thread-race technique the issue asked for: every match operation
//! (`hostIsMatch` / `hostMatchOne` / `hostReplace`) runs the actual
//! `Matcher` call on a fresh background `java.lang.Thread`, marked daemon,
//! while the calling thread blocks on `Thread.join(timeoutMs)` — a bounded
//! wait, unlike `Future.get()`. `Regex` is therefore no longer a bare
//! `extern type` alias for `Pattern`; it is a small Lyric record pairing
//! the compiled `Pattern` with the timeout (milliseconds) baked in by
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
//!     Passing the match closure to `Thread.new(...)` uses the JVM
//!     backend's existing Lyric-closure-to-functional-interface SAM
//!     bridging (`Jvm.Codegen.ensureSamAdapterClass`,
//!     `codegen/04_calls.l` — already proven for arbitrary JDK functional
//!     interfaces, `Runnable` included), so no hand-written Java shim class
//!     is needed.
//!   - Documented tradeoff, same as every daemon-thread-race timeout
//!     technique on the JVM: `java.util.regex` is not interruptible (no
//!     backtracking checkpoint observes `Thread.interrupt()`), so a timed-
//!     out match is *abandoned* running rather than stopped — the caller is
//!     unblocked within the deadline (the actual ReDoS protection: an
//!     attacker can no longer tie up the calling thread indefinitely), but
//!     the abandoned background thread may keep burning CPU until it
//!     finishes naturally or the JVM exits. Marking it daemon guarantees it
//!     never blocks JVM shutdown. A fully leak-free fix needs an
//!     interruptible `CharSequence` wrapper around the match input (its
//!     `charAt`/`length` observing the deadline and throwing) so the
//!     backtracking loop itself notices promptly — a real further
//!     improvement, but out of scope here: the issue asked specifically for
//!     the daemon-thread shim, and this closes the actual vulnerability
//!     (unbounded blocking) that #330/#1103 track.
//!   - Residual surface this shim does NOT close: a caller that
//!     re-invokes the same vulnerable pattern repeatedly (e.g. once per
//!     HTTP request) accumulates one abandoned, permanently-running
//!     daemon thread per timed-out call — each call is individually
//!     bounded, but nothing caps the number of them in flight, so
//!     sustained attack traffic is still a real multi-request CPU/thread
//!     exhaustion risk. See #6576 (tracked follow-up: `Thread.ofVirtual()`
//!     or a bounded pool instead of one platform `Thread` per call).
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
// Exactly one of `timedOut` / (not timedOut) applies; when not timed out,
// `faulted` distinguishes "action ran to completion successfully" (the
// caller's own captured `var`s hold the real result) from "action threw"
// (`faultMessage` carries the original exception's message, re-panicked by
// the caller so unrelated bugs — e.g. a JVM `StackOverflowError` from a
// pathologically deep pattern — surface as themselves, not silently as a
// stale/default result).
record RaceOutcome {
  timedOut: Bool
  faulted: Bool
  faultMessage: String
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

func raceWithDeadline(action: in () -> Unit, timeoutMs: in Long): RaceOutcome {
  val hasFault: JAtomicBoolean = JAtomicBoolean.new(false)
  val faultMessage: JAtomicReference = JAtomicReference.new("")
  // The lambda literal is passed directly as the constructor argument
  // (not bound to a `val` first): `Jvm.Codegen`'s Lyric-closure-to-
  // functional-interface SAM bridging (`emitFfiCoerce`,
  // `codegen/04_calls.l`) only fires when the argument expression's own
  // static type is the package's `Lyric$Lambda` interface — a `val f: ()
  // -> Unit = { -> ... }` local's declared function-type annotation
  // erases differently, so passing `f` by name skipped the bridge and
  // handed `Thread`'s constructor the raw (non-`Runnable`) closure
  // object, verified by direct experiment (`IncompatibleClassChangeError:
  // ... does not implement the requested interface java.lang.Runnable`
  // at `Thread.run()`).
  val t = JThread.new({ -> try { action() } catch Bug as b { hasFault.set(true); faultMessage.set(b.message) }; () })
  t.setDaemon(true)
  t.start()
  t.join(timeoutMs)
  if t.isAlive() {
    RaceOutcome(timedOut = true, faulted = false, faultMessage = "")
  } else if hasFault.get() {
    val msg: String = faultMessage.get()
    RaceOutcome(timedOut = false, faulted = true, faultMessage = msg)
  } else {
    RaceOutcome(timedOut = false, faulted = false, faultMessage = "")
  }
}

// Shared deadline-exceeded message: MUST contain the literal substring
// "time-out" — `Std.Regex.isTimeout` / `Std.RegexSafe`'s classifiers scan
// for that exact phrase to route a caught `Bug` to `TimedOut` rather than
// `InvalidPattern`/`RegexBug` (see std/regex.l's `isTimeout`).
func timeoutMessage(op: in String, timeoutMs: in Long): String {
  op + " exceeded its configured time-out of " + timeoutMs.toString() + "ms"
}

// ─── Match operations ────────────────────────────────────────────────────────
/// True when `input` contains at least one match: Pattern.matcher + find(),
/// raced against `r`'s compiled-in timeout.
pub func hostIsMatch(r: in Regex, input: in String): Bool {
  var result = false
  val outcome = raceWithDeadline({ -> result = matchFind(r.pattern, input) }, r.timeoutMs)
  if outcome.timedOut {
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
  if outcome.timedOut {
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
  if outcome.timedOut {
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
