# D-progress-962 — JVM regex: enforce the match timeout inline, not with a raced thread (#7283)

**Status:** shipped

Supersedes the JVM regex part of D-progress-817 (#6576), which kept
D-progress-808's thread race and moved it onto virtual threads behind a
process-wide `matchSemaphore`.

## Context

`java.util.regex.Pattern` has no match timeout. Since #1103 the JVM kernel
(`_kernel_jvm/regex_host.l`) enforced `Std.Regex`'s timeout by starting a
thread per match operation and waiting on it with `Thread.join(timeoutMs)`.
Every `isMatch`/`matchOne`/`replace` paid for a thread start, two atomics, a
closure and a semaphore permit: about 43 us per call for a benign pattern.
Worse, a timed-out match could only be abandoned. It kept running on a shared
carrier thread until it finished, which is why D-progress-817 added a cap of
`max(64, 16 x cores)` outstanding matches, rejecting calls once it was reached.
D-progress-808 already noted that the complete fix was an input
`CharSequence` that observes the deadline itself.

## Decision

Every match operation runs on the calling thread over `DeadlineChars`, a Lyric
record implementing `java.lang.CharSequence` (the JVM `impl <extern
interface>` path, docs/51):

- `charAt` counts reads and checks `System.nanoTime()` every 1024 reads. Once
  the deadline has passed it panics with the existing "time-out" message, so
  `Std.Regex`/`Std.RegexSafe` still classify the failure as `TimedOut`.
- The backtracking engine reads its input through `charAt`, so a runaway match
  is stopped by its own reads, within microseconds of the deadline, and nothing
  is left running. The semaphore, its saturation error and `RaceOutcome` are
  removed.
- `subSequence` returns a plain `String`: the engine only uses it to extract
  groups and replacement text, never to match against.
- The view is disarmed when the operation returns, so the positioned `Matcher`
  that `hostMatchOne` hands back can still be inspected after the deadline.
  Operations on that `Matcher` afterwards are not bounded, as before.
- Engine faults other than the deadline (for example an out-of-range `$n` in a
  replacement) now propagate directly instead of being re-panicked from the
  joining thread.

A benign match costs about 0.7 us instead of 43 us.

## Verification

- `regex_jvm_deadline_self_test.l` replaces `regex_jvm_semaphore_leak_self_test.l`.
  It checks four things:
  - a `((a+)+)+$` runaway stops near a 200 ms deadline;
  - 100 consecutive timeouts each report `TimedOut`;
  - 200 replacement faults report as faults;
  - the `matchOne` `Matcher` is usable after its deadline.
- `check-regex-redos.sh` (`regex_redos_jvm_main.l`) still observes
  `Err(TimedOut)` at the configured 1.5 s deadline.
