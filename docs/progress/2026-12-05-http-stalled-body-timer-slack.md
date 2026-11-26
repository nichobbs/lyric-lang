# Stalled-body timeout test allows the dotnet timer's tick granularity (#9419)

## What shipped

- Root cause of the intermittent `not reported before the deadline: 399 ms`: the failing CI step runs the test on dotnet, where `makeCancelSourceTimeout` is `CancellationTokenSource(int)`. The BCL timer uses a millisecond tick clock and can fire before the deadline on a high-resolution clock. A standalone probe measured 3 early fires in 3000 25 ms timers (minimum 24.695 ms); adding 1 ms to the timer did not remove it (28 in 8000, minimum 22.4 ms), so a fixed margin in the kernel is unsound. The JVM and native kernels check the deadline on the measuring clock (`nanoTime`, `CLOCK_MONOTONIC`, rounded-up poll waits) and cannot fire early. #9314's call reordering was therefore not the cause.
- `http_timeout_tests.l`: the lower bound is `400 - timerSlackMs` (10 ms), with the reason in the comment. The upper bound and the assertion that the deadline ends the send are unchanged.
- `_kernel/task.l`: `makeCancelSourceTimeout` documents the dotnet early-fire behaviour.

## Remaining

A dotnet timer that never fires early would need a re-arming timer that checks a monotonic clock, which needs delegate-typed timer callbacks in the kernel; not done here.
