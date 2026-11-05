//! Creates a `Gpu.Surface` for a `Window.Window`: X11, Wayland, Windows (HWND) and macOS
//! (the window's `CAMetalLayer`), and recovers one that `Gpu.tryAcquireFrame` reports outdated
//! or lost.
@io
package GpuWindow

import Gpu
import Window

/// A surface for `w` on `d`, built from whichever window system SDL chose.
pub func surfaceFor(d: Gpu.Device, w: Window.Window): Result[Gpu.Surface, String] {
  match Window.nativeWindow(w) {
    case X11(display, window) -> Gpu.createXlibSurface(d, display, window)
    case Wayland(display, surface) -> Gpu.createWaylandSurface(d, display, surface)
    case Win32(hwnd, instance) -> Gpu.createWindowsSurface(d, instance, hwnd)
    case Cocoa(_) -> match Window.metalLayer(w) {
      case Ok(layer) -> Gpu.createMetalSurface(d, layer)
      case Err(message) -> Err(error = message)
    }
    case Unavailable -> Err(error = "this window system has no GPU surface support yet")
  }
}

/// A configured surface for `w` at its current pixel size, presenting with `mode` when the
/// surface offers it (else `Fifo`).
pub func configuredSurfaceFor(d: Gpu.Device, w: Window.Window, mode: Gpu.PresentMode): Result[Gpu.Surface, String] {
  val created = match surfaceFor(d, w) { case Ok(s) -> s; case Err(m) -> return Err(error = m) }
  val px = Window.pixelSize(w)
  match Gpu.configureSurface(d, Gpu.withPresentMode(created, mode), px.width, px.height) {
    case Ok(s) -> Ok(value = s)
    case Err(m) -> {
      Gpu.releaseSurface(created)
      Err(error = m)
    }
  }
}

/// The surface to draw `w` into after `tryAcquireFrame` returned `e`: `s` configured again at the
/// window's pixel size when it is outdated (unchanged while the window has no pixels), a new surface (with `s`'s present mode) when it was
/// lost (releasing `s` once the new one exists), and `Err` when drawing cannot continue, which
/// leaves `s` for the caller to release.
pub func recoverSurface(d: Gpu.Device, w: Window.Window, s: Gpu.Surface, e: Gpu.FrameError): Result[Gpu.Surface, String] {
  match e {
    case Outdated -> {
      val px = Window.pixelSize(w)
      // A minimized window has no pixels; keep the surface until it has some again.
      if px.width <= 0 or px.height <= 0 then Ok(value = s) else Gpu.configureSurface(d, s, px.width, px.height)
    }
    case Lost -> match configuredSurfaceFor(d, w, s.presentMode) {
      case Ok(next) -> {
        Gpu.releaseSurface(s)
        Ok(value = next)
      }
      case Err(m) -> Err(error = m)
    }
    case Failed(message) -> Err(error = message)
  }
}
