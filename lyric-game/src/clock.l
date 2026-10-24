//! clock.l - Game.Clock: a fixed-timestep accumulator (docs/67 G7).
//!
//! Game logic advances in whole steps of `1 / hz` seconds so that a session is the same on a fast
//! and a slow machine and replays exactly; rendering interpolates between the last two states by
//! the fraction of a step left over.  A frame that took far longer than a step (a stall, a
//! debugger) is capped at `maxSteps` and the remaining time is dropped, so the loop never spirals.
package Game.Clock

import Std.Core

pub ref record Clock {
  stepNanos: Long
  maxSteps: Int
  var accumulator: Long
}

/// What one frame of elapsed time bought: `steps` whole updates to run, and `alpha` in 0 to 1,
/// how far the render is between the previous update and the next.
pub record Ticks {
  steps: Int
  alpha: Float
}

/// A clock stepping `hz` times a second, running at most `maxSteps` updates per frame.
pub func newClock(hz: in Int, maxSteps: in Int): Clock
  requires: hz > 0 and maxSteps > 0
{
  Clock(stepNanos = 1000000000i64 / hz.toLong(), maxSteps = maxSteps, accumulator = 0i64)
}

/// The length of one update in seconds.
pub func stepSeconds(c: in Clock): Float {
  c.stepNanos.toFloat() / 1000000000.0f32
}

/// Adds `elapsedNanos` of real time and returns the updates to run for it.
pub func advance(c: in Clock, elapsedNanos: in Long): Ticks
  requires: elapsedNanos >= 0i64
  ensures: result.steps >= 0 and result.steps <= c.maxSteps
{
  c.accumulator = c.accumulator + elapsedNanos
  var steps = 0
  while c.accumulator >= c.stepNanos and steps < c.maxSteps {
    c.accumulator = c.accumulator - c.stepNanos
    steps = steps + 1
  }
  if c.accumulator >= c.stepNanos {
    c.accumulator = 0i64
  }
  Ticks(steps = steps, alpha = c.accumulator.toFloat() / c.stepNanos.toFloat())
}
