//! sprites.l - Game.Sprites: sprite-sheet cells and animation timing (docs/67 G7).
//!
//! Pure bookkeeping; `Game.Draw` in the platform project draws the cells.
package Game.Sprites

import Std.Core
import Std.Collections

/// An image divided into a grid of equal cells, numbered left to right, top to bottom.
pub record Sheet {
  cellWidth: Int
  cellHeight: Int
  columns: Int
  rows: Int
}

/// A cell's top-left corner and size in image pixels.
pub record Cell {
  x: Int
  y: Int
  width: Int
  height: Int
}

pub func cellOf(s: in Sheet, index: in Int): Cell
  requires: index >= 0 and index < s.columns * s.rows
{
  Cell(
    x = index % s.columns * s.cellWidth,
    y = index / s.columns * s.cellHeight,
    width = s.cellWidth,
    height = s.cellHeight
  )
}

/// A looping or one-shot sequence of cells shown for `frameSeconds` each.
pub record Animation {
  cells: List[Int]
  frameSeconds: Float
  looping: Bool
}

/// The cell shown `seconds` after the animation started.
pub func cellAt(a: in Animation, seconds: in Float): Int
  requires: a.cells.count > 0 and a.frameSeconds > 0.0f32
{
  val n = (seconds / a.frameSeconds).toInt()
  val i = if n < 0 {
    0
  } else if a.looping {
    n % a.cells.count
  } else if n >= a.cells.count {
    a.cells.count - 1
  } else {
    n
  }
  a.cells[i]
}
