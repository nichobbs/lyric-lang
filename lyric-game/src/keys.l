//! keys.l - Game.Keys: key codes for `Game.Input` (docs/67 G7).
//!
//! These are SDL3 keycodes, which `lyric-window` reports unchanged: printable keys are their
//! Unicode value (lowercase letters, digits), and the rest are `SDLK_SCANCODE_MASK | scancode`.
package Game.Keys

pub val space: Int = 32

pub val enter: Int = 13

pub val escape: Int = 27

pub val tab: Int = 9

pub val backspace: Int = 8

pub val right: Int = 1073741903

pub val left: Int = 1073741904

pub val down: Int = 1073741905

pub val up: Int = 1073741906

pub val keyA: Int = 97

pub val keyD: Int = 100

pub val keyS: Int = 115

pub val keyW: Int = 119

pub val keyP: Int = 112

pub val keyR: Int = 114
