//! theme.l - Ui.Native.Theme: the design tokens of the native host (docs/65 §13.9, docs/67 G10).
//!
//! The same tokens `runtime/ui.css` defines for the web host, as plain data so the layout engine
//! and the painter agree on them without either importing the other.  Colours are straight RGBA
//! in 0 to 1; sizes are logical pixels.  A host picks `light()` or `dark()`.
@pure
package Ui.Native.Theme

import Std.Core

pub record Rgba {
  r: Float
  g: Float
  b: Float
  a: Float
}

pub func rgb(r: Float, g: Float, b: Float): Rgba {
  Rgba(r = r, g = g, b = b, a = 1.0f32)
}

pub func hex(v: Int): Rgba {
  Rgba(
    r = v.shr(16).and(255).toFloat() / 255.0f32,
    g = v.shr(8).and(255).toFloat() / 255.0f32,
    b = v.and(255).toFloat() / 255.0f32,
    a = 1.0f32
  )
}

pub func withAlpha(c: Rgba, a: Float): Rgba {
  Rgba(r = c.r, g = c.g, b = c.b, a = a)
}

/// Text styles, by index, which `Metrics` and the painter map to a font.
pub val styleBody: Int = 0

pub val styleBold: Int = 1

pub val styleSmall: Int = 2

pub val styleH1: Int = 3

pub val styleH2: Int = 4

pub val styleH3: Int = 5

pub val styleCount: Int = 6

pub record Theme {
  bg: Rgba
  surface: Rgba
  text: Rgba
  muted: Rgba
  border: Rgba
  accent: Rgba
  accentText: Rgba
  danger: Rgba
  info: Rgba
  success: Rgba
  warning: Rgba
  radius: Float
  gap: Float
  pagePadding: Float
  pageMaxWidth: Float
  controlHeight: Float
  inputPadding: Float
  fontSize: Float
}

pub func light(): Theme {
  Theme(
    bg = hex(0xf7f7f8),
    surface = hex(0xffffff),
    text = hex(0x1d1d21),
    muted = hex(0x5d5d66),
    border = hex(0xd6d6dc),
    accent = hex(0x2f5bd3),
    accentText = hex(0xffffff),
    danger = hex(0xb3261e),
    info = hex(0x1f5fa8),
    success = hex(0x1e7b3a),
    warning = hex(0x8a5a00),
    radius = 6.0f32,
    gap = 12.0f32,
    pagePadding = 24.0f32,
    pageMaxWidth = 960.0f32,
    controlHeight = 36.0f32,
    inputPadding = 9.0f32,
    fontSize = 15.0f32
  )
}

pub func dark(): Theme {
  light().copy(
    bg = hex(0x151518),
    surface = hex(0x1f1f24),
    text = hex(0xececf1),
    muted = hex(0xa5a5b0),
    border = hex(0x3a3a44),
    accent = hex(0x7c9cff),
    accentText = hex(0x0e0e12),
    danger = hex(0xff8a80),
    info = hex(0x8ab4f8),
    success = hex(0x81c995),
    warning = hex(0xfdd663)
  )
}

/// The colour a `tone` property names (`error`, `warning`, `success`, `info`).
pub func toneColour(t: in Theme, tone: in String): Rgba {
  if tone == "error" {
    t.danger
  } else if tone == "warning" {
    t.warning
  } else if tone == "success" {
    t.success
  } else {
    t.info
  }
}
