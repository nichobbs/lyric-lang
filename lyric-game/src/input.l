//! input.l - Game.Input: per-step input snapshots (docs/67 G7).
//!
//! Game logic never sees the window system.  It sees an `InputFrame`, an immutable snapshot of
//! what is held and what changed during one update step, built purely from the previous frame
//! and the events that arrived since: `next(prev, events)`.  The same function builds the frames
//! of a live session and of a replay, so a recorded event stream reproduces a session exactly.
//!
//! Pointer positions and wheel deltas are fixed point, in sixteenths of a pixel (or of a wheel
//! notch).  The window system reports floats; `pointerMoved` and `scrolled` round them once, at
//! the boundary, so what is recorded is what the game saw.
package Game.Input

import Std.Core
import Std.Collections

/// A key, a button or the pointer changed.  `key` is the window system's key code.
pub union InputEvent {
  case KeyPressed(key: Int)
  case KeyReleased(key: Int)
  case PointerMoved(x16: Int, y16: Int)
  case ButtonPressed(button: Int)
  case ButtonReleased(button: Int)
  case Scrolled(dx16: Int, dy16: Int)
  case TextTyped(text: String)
}

/// What the game sees for one update step.
pub record InputFrame {
  down: List[Int]
  pressed: List[Int]
  released: List[Int]
  buttons: Int
  buttonsPressed: Int
  buttonsReleased: Int
  pointerX16: Int
  pointerY16: Int
  wheelX16: Int
  wheelY16: Int
  text: String
  events: List[InputEvent]
}

val fixedScale: Int = 16

func quantise(v: Float): Int {
  val scaled = v * 16.0f32
  if scaled >= 0.0f32 {
    (scaled + 0.5f32).toInt()
  } else {
    -((0.0f32 - scaled + 0.5f32).toInt())
  }
}

pub func pointerMoved(x: Float, y: Float): InputEvent {
  PointerMoved(x16 = quantise(x), y16 = quantise(y))
}

pub func scrolled(dx: Float, dy: Float): InputEvent {
  Scrolled(dx16 = quantise(dx), dy16 = quantise(dy))
}

/// The frame before any input: nothing held, the pointer at the origin.
pub func initialFrame(): InputFrame {
  InputFrame(
    down = newList(),
    pressed = newList(),
    released = newList(),
    buttons = 0,
    buttonsPressed = 0,
    buttonsReleased = 0,
    pointerX16 = 0,
    pointerY16 = 0,
    wheelX16 = 0,
    wheelY16 = 0,
    text = "",
    events = newList()
  )
}

func containsKey(keys: List[Int], key: Int): Bool {
  for k in keys {
    if k == key {
      return true
    }
  }
  false
}

func withoutKey(keys: List[Int], key: Int): List[Int] {
  val kept: List[Int] = newList()
  for k in keys {
    if k != key {
      kept.add(k)
    }
  }
  kept
}

func buttonBit(button: Int): Int {
  if button < 0 or button > 30 {
    0
  } else {
    1.shl(button)
  }
}

/// The frame after `events`, which arrived since `prev`.  Held keys and buttons and the pointer
/// carry over; edges (`pressed`, `released`, the wheel, typed text) start empty.
pub func next(prev: in InputFrame, events: in List[InputEvent]): InputFrame {
  val down: List[Int] = newList()
  for k in prev.down {
    down.add(k)
  }
  val pressed: List[Int] = newList()
  val released: List[Int] = newList()
  val applied: List[InputEvent] = newList()
  var buttons = prev.buttons
  var buttonsPressed = 0
  var buttonsReleased = 0
  var px = prev.pointerX16
  var py = prev.pointerY16
  var wx = 0
  var wy = 0
  var text = ""
  var held = down
  for e in events {
    applied.add(e)
    match e {
      case KeyPressed(key) -> {
        if not containsKey(held, key) {
          held.add(key)
          pressed.add(key)
        }
      }
      case KeyReleased(key) -> {
        if containsKey(held, key) {
          held = withoutKey(held, key)
          released.add(key)
        }
      }
      case PointerMoved(x16, y16) -> {
        px = x16
        py = y16
      }
      case ButtonPressed(button) -> {
        val bit = buttonBit(button)
        if buttons.and(bit) == 0 {
          buttons = buttons.or(bit)
          buttonsPressed = buttonsPressed.or(bit)
        }
      }
      case ButtonReleased(button) -> {
        val bit = buttonBit(button)
        if buttons.and(bit) != 0 {
          buttons = buttons.and(bit.xor(-1))
          buttonsReleased = buttonsReleased.or(bit)
        }
      }
      case Scrolled(dx16, dy16) -> {
        wx = wx + dx16
        wy = wy + dy16
      }
      case TextTyped(t) -> {
        text = text + t
      }
    }
  }
  InputFrame(
    down = held,
    pressed = pressed,
    released = released,
    buttons = buttons,
    buttonsPressed = buttonsPressed,
    buttonsReleased = buttonsReleased,
    pointerX16 = px,
    pointerY16 = py,
    wheelX16 = wx,
    wheelY16 = wy,
    text = text,
    events = applied
  )
}

/// The frame for a later update step of the same rendered frame: what is held stays held, and no
/// edge fires twice.
pub func carry(prev: in InputFrame): InputFrame {
  next(prev, newList())
}

pub func isDown(f: in InputFrame, key: in Int): Bool {
  containsKey(f.down, key)
}

pub func wasPressed(f: in InputFrame, key: in Int): Bool {
  containsKey(f.pressed, key)
}

pub func wasReleased(f: in InputFrame, key: in Int): Bool {
  containsKey(f.released, key)
}

pub func buttonDown(f: in InputFrame, button: in Int): Bool {
  f.buttons.and(buttonBit(button)) != 0
}

pub func buttonPressed(f: in InputFrame, button: in Int): Bool {
  f.buttonsPressed.and(buttonBit(button)) != 0
}

pub func buttonReleased(f: in InputFrame, button: in Int): Bool {
  f.buttonsReleased.and(buttonBit(button)) != 0
}

pub func pointerX(f: in InputFrame): Float {
  f.pointerX16.toFloat() / 16.0f32
}

pub func pointerY(f: in InputFrame): Float {
  f.pointerY16.toFloat() / 16.0f32
}

pub func wheelX(f: in InputFrame): Float {
  f.wheelX16.toFloat() / 16.0f32
}

pub func wheelY(f: in InputFrame): Float {
  f.wheelY16.toFloat() / 16.0f32
}
