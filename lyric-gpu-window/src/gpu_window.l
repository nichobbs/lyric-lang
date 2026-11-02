//! Creates a `Gpu.Surface` for a `Window.Window`: X11, Wayland, Windows (HWND) and macOS
//! (the window's `CAMetalLayer`).
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
