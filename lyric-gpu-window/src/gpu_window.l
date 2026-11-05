//! Opens a GPU device for a `Window.Window` and creates its `Gpu.Surface`: X11, Wayland, Windows (HWND) and macOS
//! (the window's `CAMetalLayer`), and recovers one that `Gpu.tryAcquireFrame` reports outdated
//! or lost.
@io
package GpuWindow

import Gpu
import Window

/// The window-system handle `w` presents to, from whichever window system SDL chose.
pub func sourceFor(w: Window.Window): Result[Gpu.SurfaceSource, String] {
  match Window.nativeWindow(w) {
    case X11(display, window) -> Ok(value = Gpu.XlibSource(display = display, window = window))
    case Wayland(display, surface) -> Ok(value = Gpu.WaylandSource(display = display, surface = surface))
    case Win32(hwnd, instance) -> Ok(value = Gpu.WindowsSource(instance = instance, hwnd = hwnd))
    case Cocoa(_) -> match Window.metalLayer(w) {
      case Ok(layer) -> Ok(value = Gpu.MetalSource(layer = layer))
      case Err(message) -> Err(error = message)
    }
    case Unavailable -> Err(error = "this window system has no GPU surface support yet")
  }
}

/// A surface for `w` on `d`.
pub func surfaceFor(d: Gpu.Device, w: Window.Window): Result[Gpu.Surface, String] {
  match sourceFor(w) {
    case Ok(source) -> Gpu.createSurface(d, source)
    case Err(m) -> Err(error = m)
  }
}

/// Opens a device on an adapter that can present to `w` (`Gpu.withDeviceFor`), configures a
/// surface for it at the window's pixel size presenting with `mode` (or `Fifo`), and runs
/// `body` with both.  `body` owns the surface: it keeps the one `recoverSurface` returns and
/// releases the one it ends with.
pub func withWindowDevice[T](
  w: Window.Window, mode: Gpu.PresentMode, body: (Gpu.Device, Gpu.Surface) -> T
): Result[T, String] {
  val source = match sourceFor(w) { case Ok(s) -> s; case Err(m) -> return Err(error = m) }
  val inner: (Gpu.Device, Gpu.Surface) -> Result[T, String] = { d: Gpu.Device, created: Gpu.Surface ->
    val px = Window.pixelSize(w)
    match Gpu.configureSurface(d, Gpu.withPresentMode(created, mode), px.width, px.height) {
      case Ok(surface) -> Ok(value = body(d, surface))
      case Err(m) -> {
        Gpu.releaseSurface(created)
        Err(error = m)
      }
    }
  }
  match Gpu.withDeviceFor(source, inner) {
    case Ok(outcome) -> outcome
    case Err(m) -> Err(error = m)
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
