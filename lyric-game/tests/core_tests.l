@test_module
package Game.CoreTests

import Std.Core
import Std.Collections
import Std.Testing
import Game.Clock
import Game.Rng
import Game.Input
import Game.Replay

func eqI(a: Int, b: Int): Unit {
  assertEqualInt(a, b, "int")
}

func eqL(a: Long, b: Long): Unit {
  assertEqualLong(a, b, "long")
}

func eqF(a: Float, b: Float): Unit {
  assertTrue(a == b, "float " + a.toString() + " vs " + b.toString())
}

test "clock runs whole steps and keeps the remainder" {
  val c = newClock(60, 5)
  val t = advance(c, 50000000i64)
  eqI(t.steps, 3)
  assertTrue(t.alpha > 0.0f32 and t.alpha < 1.0f32, "alpha is the leftover fraction")
}

test "clock caps a stall and drops the rest" {
  val c = newClock(60, 5)
  val t = advance(c, 10000000000i64)
  eqI(t.steps, 5)
  eqI(advance(c, 0i64).steps, 0)
}

test "rng is deterministic and bounded" {
  val a = seeded(42i64)
  val b = seeded(42i64)
  var i = 0
  while i < 1000 {
    val x = nextBelow(a, 100)
    eqI(x, nextBelow(b, 100))
    assertTrue(x >= 0 and x < 100, "in range")
    i = i + 1
  }
  val c = seeded(0i64)
  assertTrue(nextInt(c) != nextInt(c), "seed zero still moves")
}

test "input frames track held keys and edges" {
  val f0 = initialFrame()
  val f1 = next(f0, [KeyPressed(key = 97), pointerMoved(10.25f32, 20.5f32)])
  assertTrue(isDown(f1, 97), "held")
  assertTrue(wasPressed(f1, 97), "pressed edge")
  eqF(pointerX(f1), 10.25f32)
  val f2 = carry(f1)
  assertTrue(isDown(f2, 97), "still held")
  assertFalse(wasPressed(f2, 97), "edge does not repeat")
  val f3 = next(f2, [KeyReleased(key = 97), ButtonPressed(button = 1)])
  assertFalse(isDown(f3, 97), "released")
  assertTrue(wasReleased(f3, 97), "release edge")
  assertTrue(buttonDown(f3, 1) and buttonPressed(f3, 1), "button")
  eqF(pointerX(f3), 10.25f32)
}

test "replay text round-trips and rebuilds the same frames" {
  val r = newRecording(777i64)
  record(r, [KeyPressed(key = 97), pointerMoved(1.5f32, 2.0f32)])
  record(r, [])
  record(r, [TextTyped(text = "hé"), scrolled(0.0f32, -1.0f32), ButtonPressed(button = 1)])
  record(r, [KeyReleased(key = 97), ButtonReleased(button = 1)])
  val text = encode(r)
  match decode(text) {
    case Err(e) -> assertTrue(false, e)
    case Ok(back) -> {
      eqL(back.seed, 777i64)
      assertEqual(encode(back), text, "text")
      val a = frames(r)
      val b = frames(back)
      eqI(a.count, 4)
      assertEqual(b[2].text, "hé", "text")
      eqI(b[2].wheelY16, -16)
      assertTrue(isDown(b[0], 97) and not isDown(b[3], 97), "keys replay")
      eqI(b[3].buttons, 0)
    }
  }
}

test "replay reads CRLF line ends" {
  match decode("lyric-replay 1\r\nseed 7\r\nK+97\r\n\r\nK-97\r\n") {
    case Ok(r) -> {
      eqL(r.seed, 7i64)
      eqI(r.steps.count, 3)
      eqI(r.steps[0].count, 1)
      eqI(r.steps[1].count, 0)
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "replay rejects damage" {
  match decode("lyric-replay 1\nseed 1\nK+x\n") {
    case Ok(_) -> assertTrue(false, "should not read")
    case Err(e) -> assertTrue(e.length > 0, "names the line")
  }
  match decode("nope") {
    case Ok(_) -> assertTrue(false, "should not read")
    case Err(_) -> ()
  }
}
