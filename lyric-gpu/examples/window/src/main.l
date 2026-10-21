//! window: a blue window with a red triangle, drawn through a wgpu surface for an SDL3 window.
//! It draws frames for `seconds` seconds (default 4) or until the window is closed, so a test
//! can screenshot the window while it is up.
//!   window [seconds]
package Gpu.Examples.Window

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Environment as Environment
import Std.Parse
import Gpu
import Window

val size: Int = 256

val shader: String = "@vertex\nfn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {\n  var p = array<vec2<f32>, 3>(vec2<f32>(0.0, 0.8), vec2<f32>(-0.8, -0.8), vec2<f32>(0.8, -0.8));\n  return vec4<f32>(p[i], 0.0, 1.0);\n}\n@fragment\nfn fs() -> @location(0) vec4<f32> {\n  return vec4<f32>(1.0, 0.0, 0.0, 1.0);\n}\n"

val noLayouts: List[Gpu.VertexLayout] = []

val noBuffers: List[Gpu.Buffer] = []

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func isQuit(e: Window.Event): Bool {
  match e {
    case Quit -> true
    case WindowCloseRequested(w) -> true
    case _ -> false
  }
}

// True once a quit or close event has been queued.
func closeRequested(): Bool {
  var closed = false
  var more = true
  while more {
    match Window.pollEvent() {
      case None -> {
        more = false
      }
      case Some(e) -> if isQuit(e) { closed = true }
    }
  }
  closed
}

func surfaceFor(d: Gpu.Device, w: Window.Window): Result[Gpu.Surface, String] {
  match Window.nativeWindow(w) {
    case X11(display, window) -> Gpu.createXlibSurface(d, display, window)
    case Wayland(display, surface) -> Gpu.createWaylandSurface(d, display, surface)
    case _ -> Err(error = "this window system has no surface support yet")
  }
}

func drawFrames(d: Gpu.Device, surface: Gpu.Surface, frames: Int): Result[Unit, String] {
  val pipeline = match Gpu.createRenderPipeline(d, shader, "vs", "fs", noLayouts, surface.format) {
    case Ok(p) -> p
    case Err(e) -> return Err(error = e)
  }
  var frame = 0
  while frame < frames and not closeRequested() {
    match Gpu.acquireFrame(d, surface) {
      case Err(message) -> return Err(error = message)
      case Ok(target) -> {
        val draws: List[Gpu.Draw] = newList()
        draws.add(Gpu.Draw(pipeline = pipeline, bindGroup = None, vertexBuffers = noBuffers, vertexCount = 3))
        match Gpu.render(d, target, 0.0, 0.0, 1.0, 1.0, draws) {
          case Err(message) -> return Err(error = message)
          case Ok(_) -> ()
        }
        match Gpu.presentFrame(surface, target) {
          case Err(message) -> return Err(error = message)
          case Ok(_) -> ()
        }
        if frame == 0 {
          Console.println("presented")
        }
      }
    }
    Window.delayNanos(16000000)
    frame = frame + 1
  }
  Gpu.releaseRenderPipeline(pipeline)
  Ok(value = ())
}

func run(win: Window.Window, frames: Int): Int {
  val body: (Gpu.Device) -> Int = { d: Gpu.Device ->
    match surfaceFor(d, win) {
      case Err(message) -> fail(message)
      case Ok(created) -> match Gpu.configureSurface(d, created, size, size) {
        case Err(message) -> fail(message)
        case Ok(surface) -> {
          Console.println("surface format " + surface.format.toString())
          val outcome = drawFrames(d, surface, frames)
          Gpu.releaseSurface(surface)
          match outcome {
            case Ok(_) -> 0
            case Err(message) -> fail(message)
          }
        }
      }
    }
  }
  match Gpu.withDevice(body) {
    case Err(message) -> fail(message)
    case Ok(rc) -> rc
  }
}

func main(): Int {
  val args = Environment.args()
  var seconds = 4
  if args.length > 1 {
    match parseOptInt(args[args.length - 1]) {
      case Some(n) -> {
        seconds = n
      }
      case None -> ()
    }
  }
  match Window.init(Window.initVideo) {
    case Err(message) -> return fail(message)
    case Ok(_) -> ()
  }
  val win = match Window.createWindow("Lyric window", size, size, false) {
    case Ok(w) -> w
    case Err(message) -> return fail(message)
  }
  Window.show(win)
  val rc = run(win, seconds * 60)
  Window.destroyWindow(win)
  Window.quit()
  rc
}
