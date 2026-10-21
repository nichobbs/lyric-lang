//! program.l - Game.Program: stepping a game from a recording (docs/67 G7).
//!
//! A game is `init(seed)` and `update(state, input, dt)`, both pure.  `simulate` runs a recording
//! through them exactly as the live loop would, one update per recorded step, so a recorded
//! session is a regression test that needs no window, GPU or sound card.
package Game.Program

import Std.Core
import Std.Collections
import Game.Input
import Game.Replay

/// Every state of a replay: the initial state, then the state after each recorded step.
pub func simulate[S](init: in (Long) -> S, update: in (S, InputFrame, Float) -> S, hz: in Int, r: in Recording): List[S]
  requires: hz > 0
{
  val dt = 1.0f32 / hz.toFloat()
  val states: List[S] = newList()
  var state = init(r.seed)
  states.add(state)
  for frame in frames(r) {
    state = update(state, frame, dt)
    states.add(state)
  }
  states
}

/// The state after the whole recording.
pub func finalState[S](init: in (Long) -> S, update: in (S, InputFrame, Float) -> S, hz: in Int, r: in Recording): S
  requires: hz > 0
{
  val dt = 1.0f32 / hz.toFloat()
  var state = init(r.seed)
  for frame in frames(r) {
    state = update(state, frame, dt)
  }
  state
}
