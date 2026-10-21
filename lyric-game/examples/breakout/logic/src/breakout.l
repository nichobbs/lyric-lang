//! breakout.l - Breakout: the rules of a small brick-breaking game (docs/67 G7 sample).
//!
//! The whole game is `start(seed)` and `update(state, input, dt)`: pure functions of the previous
//! state and the step's input, with no clock, window or host randomness.  Rendering and sound are
//! somebody else's job; a step reports sounds as cue ids in `State.cues`.  Recording a session's
//! input therefore reproduces it exactly, which is how the tests drive it.
//!
//! Coordinates are the playfield's own, 320 by 240, y growing downward.
package Breakout

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Math as M
import Game.Input
import Game.Keys
import Game.Rng

pub val fieldWidth: Float = 320.0f32

pub val fieldHeight: Float = 240.0f32

pub val brickColumns: Int = 10

pub val brickRows: Int = 5

pub val brickWidth: Float = 28.0f32

pub val brickHeight: Float = 10.0f32

pub val brickLeft: Float = 9.0f32

pub val brickTop: Float = 30.0f32

pub val brickStrideX: Float = 30.0f32

pub val brickStrideY: Float = 14.0f32

pub val paddleY: Float = 222.0f32

pub val paddleWidth: Float = 48.0f32

pub val paddleHeight: Float = 6.0f32

pub val ballRadius: Float = 3.0f32

val paddleSpeed: Float = 260.0f32

val ballSpeed: Float = 240.0f32

val startLives: Int = 3

val brickPoints: Int = 10

pub val modeServing: Int = 0

pub val modePlaying: Int = 1

pub val modeWon: Int = 2

pub val modeLost: Int = 3

pub val cuePaddle: Int = 0

pub val cueBrick: Int = 1

pub val cueWall: Int = 2

pub val cueLoseLife: Int = 3

pub val cueWin: Int = 4

pub record State {
  mode: Int
  seed: Long
  serves: Int
  paddleX: Float
  prevPaddleX: Float
  ballX: Float
  ballY: Float
  prevBallX: Float
  prevBallY: Float
  ballVX: Float
  ballVY: Float
  bricks: buffer[Int]
  remaining: Int
  score: Int
  lives: Int
  cues: List[Int]
}

pub func start(seed: in Long): State {
  val bricks = Buf.filled(brickColumns * brickRows, 1)
  val paddleX = fieldWidth / 2.0f32
  State(
    mode = modeServing,
    seed = seed,
    serves = 0,
    paddleX = paddleX,
    prevPaddleX = paddleX,
    ballX = paddleX,
    ballY = paddleY - ballRadius - 1.0f32,
    prevBallX = paddleX,
    prevBallY = paddleY - ballRadius - 1.0f32,
    ballVX = 0.0f32,
    ballVY = 0.0f32,
    bricks = bricks,
    remaining = brickColumns * brickRows,
    score = 0,
    lives = startLives,
    cues = newList()
  )
}

pub func brickX(column: in Int): Float {
  brickLeft + column.toFloat() * brickStrideX
}

pub func brickY(row: in Int): Float {
  brickTop + row.toFloat() * brickStrideY
}

func clampPaddle(x: Float): Float {
  val half = paddleWidth / 2.0f32
  if x < half {
    half
  } else if x > fieldWidth - half {
    fieldWidth - half
  } else {
    x
  }
}

func movedPaddle(s: State, f: InputFrame, dt: Float): Float {
  var x = s.paddleX
  if isDown(f, left) or isDown(f, keyA) {
    x = x - paddleSpeed * dt
  }
  if isDown(f, right) or isDown(f, keyD) {
    x = x + paddleSpeed * dt
  }
  for e in f.events {
    match e {
      case PointerMoved(x16, y16) -> {
        x = x16.toFloat() / 16.0f32
      }
      case _ -> ()
    }
  }
  clampPaddle(x)
}

// Launch directions as unit vectors, picked by the serve counter and seed.
func launchVelocity(s: State): List[Float] {
  val r = seeded(s.seed + s.serves.toLong() * 7919i64)
  val pick = nextBelow(r, 4)
  val v: List[Float] = newList()
  if pick == 0 {
    v.add(-0.6f32 * ballSpeed)
    v.add(-0.8f32 * ballSpeed)
  } else if pick == 1 {
    v.add(-0.28f32 * ballSpeed)
    v.add(-0.96f32 * ballSpeed)
  } else if pick == 2 {
    v.add(0.28f32 * ballSpeed)
    v.add(-0.96f32 * ballSpeed)
  } else {
    v.add(0.6f32 * ballSpeed)
    v.add(-0.8f32 * ballSpeed)
  }
  v
}

func launchPressed(f: InputFrame): Bool {
  wasPressed(f, space) or wasPressed(f, up) or buttonPressed(f, 1)
}

func restartPressed(f: InputFrame): Bool {
  wasPressed(f, enter) or wasPressed(f, space) or wasPressed(f, keyR)
}

func sqrtF(v: Float): Float {
  M.sqrt(v.toDouble()).toFloat()
}

/// Advances the game by one step of `dt` seconds.
pub func update(s: in State, f: in InputFrame, dt: in Float): State {
  if s.mode == modeWon or s.mode == modeLost {
    if restartPressed(f) {
      return start(s.seed + 1i64)
    }
    return s.copy(cues = newList(), prevPaddleX = s.paddleX, prevBallX = s.ballX, prevBallY = s.ballY)
  }
  val px = movedPaddle(s, f, dt)
  if s.mode == modeServing {
    val bx = px
    val by = paddleY - ballRadius - 1.0f32
    if launchPressed(f) {
      val v = launchVelocity(s)
      return s.copy(
        mode = modePlaying,
        serves = s.serves + 1,
        prevPaddleX = s.paddleX,
        paddleX = px,
        prevBallX = bx,
        prevBallY = by,
        ballX = bx,
        ballY = by,
        ballVX = v[0],
        ballVY = v[1],
        cues = newList()
      )
    }
    return s.copy(
      prevPaddleX = s.paddleX,
      paddleX = px,
      prevBallX = s.ballX,
      prevBallY = s.ballY,
      ballX = bx,
      ballY = by,
      cues = newList()
    )
  }
  playing(s, px, dt)
}

func playing(s: State, px: Float, dt: Float): State {
  val cues: List[Int] = newList()
  var x = s.ballX + s.ballVX * dt
  var y = s.ballY + s.ballVY * dt
  var vx = s.ballVX
  var vy = s.ballVY
  if x < ballRadius {
    x = ballRadius
    vx = -vx
    cues.add(cueWall)
  } else if x > fieldWidth - ballRadius {
    x = fieldWidth - ballRadius
    vx = -vx
    cues.add(cueWall)
  }
  if y < ballRadius {
    y = ballRadius
    vy = -vy
    cues.add(cueWall)
  }
  val half = paddleWidth / 2.0f32
  if vy > 0.0f32 and y + ballRadius >= paddleY and y - ballRadius <= paddleY + paddleHeight and x >= px - half - ballRadius and
      x <= px + half + ballRadius {
    val offset = (x - px) / (half + ballRadius)
    val nvx = offset * ballSpeed * 0.8f32
    val nvy = sqrtF(ballSpeed * ballSpeed - nvx * nvx)
    vx = nvx
    vy = -nvy
    y = paddleY - ballRadius
    cues.add(cuePaddle)
  }
  var bricks = s.bricks
  var remaining = s.remaining
  var score = s.score
  var hit = false
  var r = 0
  while r < brickRows and not hit {
    var c = 0
    while c < brickColumns and not hit {
      val i = r * brickColumns + c
      if bricks[i] > 0 {
        val bx0 = brickX(c)
        val by0 = brickY(r)
        val overlapX = if x + ballRadius < bx0 or x - ballRadius > bx0 + brickWidth { 0.0f32 } else {
          minF(x + ballRadius - bx0, bx0 + brickWidth - (x - ballRadius))
        }
        val overlapY = if y + ballRadius < by0 or y - ballRadius > by0 + brickHeight { 0.0f32 } else {
          minF(y + ballRadius - by0, by0 + brickHeight - (y - ballRadius))
        }
        if overlapX > 0.0f32 and overlapY > 0.0f32 {
          bricks[i] = 0
          remaining = remaining - 1
          score = score + brickPoints
          if overlapX < overlapY {
            vx = -vx
          } else {
            vy = -vy
          }
          cues.add(cueBrick)
          hit = true
        }
      }
      c = c + 1
    }
    r = r + 1
  }
  var mode = modePlaying
  var lives = s.lives
  var bx = x
  var by = y
  if remaining == 0 {
    mode = modeWon
    cues.add(cueWin)
  } else if y - ballRadius > fieldHeight {
    lives = lives - 1
    cues.add(cueLoseLife)
    vx = 0.0f32
    vy = 0.0f32
    if lives == 0 {
      mode = modeLost
    } else {
      mode = modeServing
      bx = px
      by = paddleY - ballRadius - 1.0f32
    }
  }
  s.copy(
    mode = mode,
    paddleX = px,
    prevPaddleX = s.paddleX,
    ballX = bx,
    ballY = by,
    prevBallX = s.ballX,
    prevBallY = s.ballY,
    ballVX = vx,
    ballVY = vy,
    bricks = bricks,
    remaining = remaining,
    score = score,
    lives = lives,
    cues = cues
  )
}

func minF(a: Float, b: Float): Float {
  if a < b { a } else { b }
}

/// A 32-bit digest of everything that determines the game's future, for pinning a replay.
pub func digest(s: in State): Long {
  var h = 2166136261i64
  h = mix(h, s.mode.toLong())
  h = mix(h, s.score.toLong())
  h = mix(h, s.lives.toLong())
  h = mix(h, s.remaining.toLong())
  h = mix(h, s.serves.toLong())
  h = mix(h, (s.paddleX * 256.0f32).toInt().toLong())
  h = mix(h, (s.ballX * 256.0f32).toInt().toLong())
  h = mix(h, (s.ballY * 256.0f32).toInt().toLong())
  h = mix(h, (s.ballVX * 256.0f32).toInt().toLong())
  h = mix(h, (s.ballVY * 256.0f32).toInt().toLong())
  var i = 0
  while i < s.bricks.length {
    h = mix(h, s.bricks[i].toLong())
    i = i + 1
  }
  h
}

func mix(h: Long, v: Long): Long {
  h.xor(v.and(0xFFFFFFFFi64)).and(0xFFFFFFFFi64) * 16777619i64 % 4294967296i64
}

func steer(events: List[InputEvent], held: InputFrame, key: Int, want: Bool): Unit {
  if want and not isDown(held, key) {
    events.add(KeyPressed(key = key))
  } else if not want and isDown(held, key) {
    events.add(KeyReleased(key = key))
  }
}

/// The input events of a simple player for this step: it chases the ball with the paddle, serves
/// when the ball is on the paddle, and ends a finished game by restarting.  `held` is the frame
/// of the previous step, so that only changes are reported.  The tests use it to record sessions.
pub func bot(s: in State, held: in InputFrame): List[InputEvent] {
  val events: List[InputEvent] = newList()
  val aim = s.ballX - ((s.remaining * 7 + s.score) % 5 - 2).toFloat() * 9.0f32
  val gap = aim - s.paddleX
  steer(events, held, left, s.mode == modePlaying and gap < -4.0f32)
  steer(events, held, right, s.mode == modePlaying and gap > 4.0f32)
  steer(events, held, space, (s.mode != modePlaying) and not isDown(held, space))
  events
}
