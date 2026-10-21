@test_module
package Breakout.Tests

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Testing
import Game.Input
import Game.Keys
import Game.Replay
import Game.Program
import Breakout

val hz: Int = 60

func begin(): State {
  start(1i64)
}

func idle(): InputFrame {
  initialFrame()
}

test "the ball waits on the paddle until serve" {
  var s = begin()
  val dt = 1.0f32 / 60.0f32
  s = update(s, next(idle(), [KeyPressed(key = left)]), dt)
  assertTrue(s.paddleX < 160.0f32, "paddle moved left")
  assertTrue(s.ballX == s.paddleX, "ball rides the paddle")
  assertEqualInt(s.mode, modeServing, "still serving")
  s = update(s, next(idle(), [KeyPressed(key = space)]), dt)
  assertEqualInt(s.mode, modePlaying, "launched")
  assertTrue(s.ballVY < 0.0f32, "ball goes up")
}

test "the paddle stays inside the field and follows the pointer" {
  var s = begin()
  val dt = 1.0f32 / 60.0f32
  var f = next(idle(), [KeyPressed(key = left)])
  var i = 0
  while i < 200 {
    s = update(s, f, dt)
    f = carry(f)
    i = i + 1
  }
  assertTrue(s.paddleX >= paddleWidth / 2.0f32, "left wall")
  s = update(s, next(idle(), [pointerMoved(100.0f32, 0.0f32)]), dt)
  assertTrue(s.paddleX == 100.0f32, "pointer sets the paddle")
}

test "a missed ball costs a life and three lose the game" {
  var s = begin()
  val dt = 1.0f32 / 60.0f32
  var held = idle()
  var steps = 0
  while s.mode != modeLost and steps < 5000 {
    val events: List[InputEvent] = if s.mode == modeServing and not isDown(held, space) {
      [KeyPressed(key = space)]
    } else if isDown(held, space) {
      [KeyReleased(key = space)]
    } else {
      []
    }
    held = next(held, events)
    s = update(s, held, dt)
    steps = steps + 1
  }
  assertEqualInt(s.mode, modeLost, "lost")
  assertEqualInt(s.lives, 0, "no lives")
}

// The bot plays `steps` updates; the recording holds exactly the events it fed.
func botSession(seed: Long, steps: Int): Recording {
  val r = newRecording(seed)
  var s = start(seed)
  var held = idle()
  val dt = 1.0f32 / 60.0f32
  var i = 0
  while i < steps {
    val events = bot(s, held)
    record(r, events)
    held = next(held, events)
    s = update(s, held, dt)
    i = i + 1
  }
  r
}

func final(r: Recording): State {
  finalState({ seed: Long -> start(seed) }, { s: State, f: InputFrame, dt: Float -> update(s, f, dt) }, hz, r)
}

test "clearing the last brick wins the game" {
  var bricks = Buf.filled(brickColumns * brickRows, 0)
  bricks[0] = 1
  val x = brickX(0) + 10.0f32
  val y = brickY(0) + brickHeight + ballRadius + 1.0f32
  val s0 = start(1i64).copy(
    mode = modePlaying,
    bricks = bricks,
    remaining = 1,
    ballX = x,
    ballY = y,
    prevBallX = x,
    prevBallY = y,
    ballVX = 0.0f32,
    ballVY = -240.0f32
  )
  val s1 = update(s0, idle(), 1.0f32 / 60.0f32)
  assertEqualInt(s1.mode, modeWon, "won")
  assertEqualInt(s1.score, 10, "scored the brick")
  assertTrue(s1.cues.count == 2 and s1.cues[0] == cueBrick and s1.cues[1] == cueWin, "cues")
  val s2 = update(s1, next(idle(), [KeyPressed(key = space)]), 1.0f32 / 60.0f32)
  assertEqualInt(s2.mode, modeServing, "space starts a new game")
  assertEqualInt(s2.remaining, brickColumns * brickRows, "fresh board")
}

test "the bot scores and keeps its lives for a while" {
  val s = final(botSession(1i64, 2000))
  assertTrue(s.score >= 300, "scored")
  assertEqualInt(s.lives, 3, "lives")
}

test "a recording replays to the same state, also through its text form" {
  val r = botSession(7i64, 1200)
  val a = final(r)
  match decode(encode(r)) {
    case Err(e) -> assertTrue(false, e)
    case Ok(back) -> {
      val b = final(back)
      assertEqualLong(digest(a), digest(b), "digest")
      assertEqualInt(a.score, b.score, "score")
    }
  }
}

test "different seeds play differently" {
  val a = final(botSession(1i64, 600))
  val b = final(botSession(2i64, 600))
  assertTrue(digest(a) != digest(b), "seeds change the game")
}

// A session recorded from the bot with seed 5 for 900 steps.  The digest pins the exact game it
// plays: any change to the rules, to Float arithmetic or to the generator moves it.
val fixture: String =
    "lyric-replay 1\nseed 5\nK+32\nK+1073741903;K-32\n\n\n\n\n\n\n\nK-1073741903\nK+1073741903\nK-1073741903\nK+107" +
    "3741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\nK-1073741903\nK+1073741903\nK-1073741903\nK" +
    "+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\nK-1073741903\nK+1073741903\nK-107374190" +
    "3\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\nK-1073741903\nK+1073741903\nK-10737" +
    "41903\nK+1073741904\n\n\nK-1073741904\n\n\nK+1073741903\nK-1073741903\nK+1073741903\n\nK-1073741903\nK+1073741" +
    "903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\nK-1073741903\nK+107" +
    "3741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\n\n\n\n\n\n\nK-1073741903\n\n\nK+1073741904" +
    "\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\n\n\n\n\n\n\n\n\n\n\n\n\nK+1073741903\nK" +
    "-1073741903\n\n\n\n\n\n\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\nK+1073741903\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n" +
    "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nK-1073741903\n\n\n\nK+1073741904\nK-1073741904\nK+1" +
    "073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK" +
    "+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904" +
    "\nK+1073741904\n\n\n\n\n\n\n\n\n\n\n\n\n\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904" +
    "\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-107374190" +
    "4\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741" +
    "904\nK+1073741904\n\nK-1073741904\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+1073741903\nK" +
    "-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741" +
    "903\nK-1073741903\n\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK" +
    "+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\n\n\n\n\n\nK-1073741903\n\nK+1073741903" +
    "\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+10737" +
    "41903\nK-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\nK" +
    "+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\n\n\n\n\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n\n" +
    "\n\n\n\n\n\n\n\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n\n\nK+1073741903\n\n\n\nK-1073741903\n\n\n\n\nK+10737" +
    "41903\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nK-1073741903\n\n\n\n\n\n\n\n\nK+107374190" +
    "4\nK-1073741904\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\nK-10737" +
    "41904\n\n\n\nK+1073741904\n\n\n\n\n\n\n\n\nK-1073741904\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\nK" +
    "-1073741904\n\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\nK-1073741904\n\n\nK+1073741904\nK-107374190" +
    "4\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n\n\nK+1" +
    "073741903\nK-1073741903\n\n\n\n\n\nK+1073741903\n\n\n\n\nK-1073741903\nK+1073741903\nK-1073741903\n\n\n\n\n\nK" +
    "+1073741903\nK-1073741903\n\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n" +
    "\nK+1073741903\nK-1073741903\n\n\n\n\n\n\nK+1073741904\nK-1073741904\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1" +
    "073741904\nK-1073741904\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\nK-1073741904\n\n\nK+1073741904\nK" +
    "-1073741904\n\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\n\n\n\n\n\n\n\n\nK-1073741904\n\n\nK+1073741" +
    "904\nK-1073741904\n\n\n\nK+1073741904\nK-1073741904\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\nK-107" +
    "3741904\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\nK-1073741904\n\n\n\nK+1073741904\nK-1073741904\n" +
    "\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-107" +
    "3741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\n\nK+107374190" +
    "3\nK-1073741903\n\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+1" +
    "073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\n\nK+1073741903\n\n\n\n\n\n\nK-1073741903\nK+1073741903" +
    "\nK-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\n\nK+107" +
    "3741903\nK-1073741903\n\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903" +
    "\n\nK+1073741903\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nK-1073741903\n\n\nK+1073741904\nK-1073741904\nK+10737" +
    "41904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+107" +
    "3741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\n\nK-1073741904\nK+1073741904\nK-1073741904\nK" +
    "+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904" +
    "\nK+1073741904\nK-1073741904\nK+1073741904\n\nK-1073741904\nK+1073741903\n\n\n\n\nK-1073741903\nK+1073741904\n" +
    "\n\nK-1073741904\n\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\nK-1073741903\nK+1" +
    "073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK" +
    "+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\nK-107374190" +
    "3\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\nK+1073741903\n\n\n\n\n\n\n\nK-1073741903\n\n\nK+107" +
    "3741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\n\n\n\n\n\n\n\n\nK+1073741903\nK" +
    "-1073741903\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n\nK+1073741903\n\n" +
    "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nK+1073741904;K-1073741903\nK-1073" +
    "741904\n\n\n\n\nK+1073741903\nK-1073741903\n\n\n\n\n\n\n\n\n\n\n\n\n\nK+1073741904\nK-1073741904\n\n\n\n\nK+10" +
    "73741904\nK-1073741904\n\n\n\nK+1073741904\nK-1073741904\n\n\n\n\nK+1073741904\nK-1073741904\n\n\n\n\n\n\nK+10" +
    "73741903\nK-1073741903\n\nK+1073741903\nK-1073741903\nK+1073741903\nK-1073741903\n\nK+1073741903\nK-1073741903" +
    "\n\n\n\n\nK+1073741904\nK-1073741904\n\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\n\nK+1073741904" +
    "\nK-1073741904\nK+1073741904\nK-1073741904\n\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\nK+107374" +
    "1904\nK-1073741904\n\nK+1073741904\nK-1073741904\nK+1073741904\nK-1073741904\n\nK+1073741904\nK-1073741904\nK+" +
    "1073741904\n"

val fixtureDigest: Long = 784632209i64

test "the checked-in recording replays to its pinned state" {
  match decode(fixture) {
    case Err(e) -> assertTrue(false, e)
    case Ok(r) -> {
      assertEqualInt(r.steps.count, 900, "steps")
      assertEqualLong(digest(final(r)), fixtureDigest, "digest")
    }
  }
}

test "the bot still records the checked-in session" {
  assertEqualLong(digest(final(botSession(5i64, 900))), fixtureDigest, "digest")
  assertEqual(encode(botSession(5i64, 900)), fixture, "recording")
}
