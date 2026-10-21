//! view.l - Breakout.View: draws a Breakout state with lyric-draw.
//!
//! The playfield is 320 by 240 game units; `Game.Run.Viewport` maps it to the window.  Moving things
//! are drawn between their previous and current positions by the fraction of a step the frame
//! is ahead.  The sprite sheets are loaded as PNG files on the first frame (an image needs the
//! painter's device); the HUD font is optional, and the game draws without text when it is missing.
@io
package Breakout.View

import Std.Core
import Std.Collections
import Std.File as File
import Std.Errors
import Draw
import Text
import Game.Image
import Game.Sprites
import Game.Run
import Breakout

/// Loaded art, filled in on the first frame.
pub record Art {
  assetDir: String
  fontPath: String
  var loaded: Bool
  var bricks: Option[Draw.Image]
  var ball: Option[Draw.Image]
  var lib: Option[Text.TextLib]
  var fonts: List[Text.Font]
}

pub func newArt(assetDir: String, fontPath: String): Art {
  Art(
    assetDir = assetDir,
    fontPath = fontPath,
    loaded = false,
    bricks = None,
    ball = None,
    lib = None,
    fonts = newList()
  )
}

val brickSheet: Sheet = Sheet(cellWidth = 28, cellHeight = 10, columns = 5, rows = 1)

func loadPng(p: Draw.Painter, path: String, pixelArt: Bool): Option[Draw.Image] {
  match File.readBytes(path) {
    case Err(_) -> None
    case Ok(bytes) -> match decodePng(bytes) {
      case Err(_) -> None
      case Ok(img) -> match loadImage(p, img, pixelArt) {
        case Ok(i) -> Some(value = i)
        case Err(_) -> None
      }
    }
  }
}

func ensureLoaded(art: Art, p: Draw.Painter): Unit {
  if art.loaded {
    return
  }
  art.loaded = true
  art.bricks = loadPng(p, art.assetDir + "/bricks.png", true)
  art.ball = loadPng(p, art.assetDir + "/ball.png", true)
  match File.readBytes(art.fontPath) {
    case Err(_) -> ()
    case Ok(bytes) -> match Text.initText() {
      case Err(_) -> ()
      case Ok(lib) -> match Text.openFont(lib, 1, bytes, 0, 14) {
        case Err(_) -> ()
        case Ok(f) -> {
          art.lib = Some(value = lib)
          art.fonts.add(f)
        }
      }
    }
  }
}

pub func release(art: Art): Unit {
  for f in art.fonts {
    Text.closeFont(f)
  }
  match art.lib {
    case Some(lib) -> Text.closeText(lib)
    case None -> ()
  }
}

func lerp(a: Float, b: Float, t: Float): Float {
  a + (b - a) * t
}

func say(art: Art, p: Draw.Painter, vp: Viewport, text: String, x: Float, y: Float, c: Draw.Color): Unit {
  if art.fonts.count > 0 {
    val at = rect(vp, x, y, 0.0f32, 0.0f32)
    match Draw.drawText(p, art.fonts, text, at.x, at.y, 0.0f32, c) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
}

pub func drawState(art: Art, prev: State, cur: State, alpha: Float, p: Draw.Painter, vp: Viewport): Unit {
  ensureLoaded(art, p)
  val white = Draw.rgb(1.0f32, 1.0f32, 1.0f32)
  Draw.fillRect(p, rect(vp, 0.0f32, 0.0f32, fieldWidth, fieldHeight), Draw.rgb(0.07f32, 0.08f32, 0.14f32))
  Draw.strokeRoundedRect(
    p,
    rect(vp, 0.0f32, 0.0f32, fieldWidth, fieldHeight),
    0.0f32,
    2.0f32,
    Draw.rgb(0.3f32, 0.35f32, 0.55f32)
  )
  var r = 0
  while r < brickRows {
    var c = 0
    while c < brickColumns {
      if cur.bricks[r * brickColumns + c] > 0 {
        val dest = rect(vp, brickX(c), brickY(r), brickWidth, brickHeight)
        match art.bricks {
          case Some(sheet) -> drawCell(p, sheet, cellOf(brickSheet, r), dest, white)
          case None -> Draw.fillRect(p, dest, Draw.rgb(0.8f32, 0.4f32, 0.3f32))
        }
      }
      c = c + 1
    }
    r = r + 1
  }
  val px = lerp(prev.paddleX, cur.paddleX, alpha)
  Draw.drawShadow(
    p,
    rect(vp, px - paddleWidth / 2.0f32, paddleY, paddleWidth, paddleHeight),
    3.0f32 * vp.scale,
    4.0f32 * vp.scale,
    Draw.rgba(0.0f32, 0.0f32, 0.0f32, 0.5f32)
  )
  Draw.fillRoundedRect(
    p,
    rect(vp, px - paddleWidth / 2.0f32, paddleY, paddleWidth, paddleHeight),
    3.0f32 * vp.scale,
    Draw.rgb(0.85f32, 0.9f32, 1.0f32)
  )
  val bx = lerp(prev.ballX, cur.ballX, alpha)
  val by = lerp(prev.ballY, cur.ballY, alpha)
  val ballDest = rect(
    vp,
    bx - ballRadius - 0.5f32,
    by - ballRadius - 0.5f32,
    ballRadius * 2.0f32 + 1.0f32,
    ballRadius * 2.0f32 + 1.0f32
  )
  match art.ball {
    case Some(img) -> Draw.drawImage(p, img, ballDest, white)
    case None -> Draw.fillRoundedRect(p, ballDest, ballRadius * vp.scale, white)
  }
  val ink = Draw.rgb(0.9f32, 0.92f32, 1.0f32)
  say(art, p, vp, "Score " + cur.score.toString(), 8.0f32, 6.0f32, ink)
  say(art, p, vp, "Lives " + cur.lives.toString(), 262.0f32, 6.0f32, ink)
  if cur.mode == modeServing {
    say(art, p, vp, "Space to serve", 112.0f32, 150.0f32, ink)
  } else if cur.mode == modeWon {
    Draw.fillRect(p, rect(vp, 0.0f32, 0.0f32, fieldWidth, fieldHeight), Draw.rgba(0.0f32, 0.0f32, 0.0f32, 0.55f32))
    say(art, p, vp, "You win!  Space to play again", 80.0f32, 110.0f32, ink)
  } else if cur.mode == modeLost {
    Draw.fillRect(p, rect(vp, 0.0f32, 0.0f32, fieldWidth, fieldHeight), Draw.rgba(0.0f32, 0.0f32, 0.0f32, 0.55f32))
    say(art, p, vp, "Game over.  Space to play again", 76.0f32, 110.0f32, ink)
  }
}
