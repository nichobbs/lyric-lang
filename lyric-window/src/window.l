//! window.l - Window: windows, input, clipboard, timing and audio for `--target native`,
//! over SDL3 (docs/67 G4).
//!
//! No `NativePtr` crosses the public surface: a window is a record around an opaque
//! handle, and an input event is a Lyric union decoded from the C event buffer.  The
//! decoder reads the fields it names at the offsets SDL3 documents; `scripts/ci/
//! window-sdl-layout-check.sh` compiles those offsets and the flag constants below
//! against SDL's own headers.
//!
//! SDL's video and audio calls belong to the thread that called `init`, normally the main
//! thread: call everything in this package from it.
@io
package Window

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Ffi as Ffi
import Window.Kernel.Sdl

/// A window, valid until `destroyWindow`.
pub record Window {
  handle: Long
  id: Int
}

/// A window's size in the window system's units or in pixels.
pub record Size {
  width: Int
  height: Int
}

/// What an input or window event says.  `window` is the id of the window it came from.
pub union Event {
  case Quit
  case WindowCloseRequested(window: Int)
  case WindowResized(window: Int, width: Int, height: Int)
  case KeyDown(window: Int, key: Int, scancode: Int, modifiers: Int, repeat: Bool)
  case KeyUp(window: Int, key: Int, scancode: Int, modifiers: Int)
  case TextInput(window: Int, text: String)
  case MouseMotion(window: Int, x: Float, y: Float, dx: Float, dy: Float)
  case MouseButtonDown(window: Int, button: Int, x: Float, y: Float, clicks: Int)
  case MouseButtonUp(window: Int, button: Int, x: Float, y: Float, clicks: Int)
  case MouseWheel(window: Int, dx: Float, dy: Float)
  case Other(kind: Int)
}

/// The handles a GPU surface is created from (`lyric-gpu`), per window system.
pub union NativeWindow {
  case X11(display: Long, window: Long)
  case Wayland(display: Long, surface: Long)
  case Cocoa(window: Long)
  case Win32(hwnd: Long, instance: Long)
  case Unavailable
}

/// An audio output: a stream of 32-bit float samples bound to a playback device.
pub record Audio {
  device: Int
  stream: Long
  channels: Int
  frequency: Int
}

pub val initVideo: Int = 32

pub val initAudio: Int = 16

val initEvents: Int = 16384

val windowResizable: Long = 32

val windowHidden: Long = 8

val windowHighPixelDensity: Long = 8192

val defaultPlaybackDevice: Int = 0 - 1

val eventQuit: Long = 256

val eventWindowResized: Long = 518

val eventWindowCloseRequested: Long = 528

val eventKeyDown: Long = 768

val eventKeyUp: Long = 769

val eventTextInput: Long = 771

val eventMouseMotion: Long = 1024

val eventMouseButtonDown: Long = 1025

val eventMouseButtonUp: Long = 1026

val eventMouseWheel: Long = 1027

// Offsets into SDL_Event, which is a union of structs that all start with
// { Uint32 type; Uint32 reserved; Uint64 timestamp; Uint32 windowID }.
val eventBufferSize: Long = 128

val offWindowId: Long = 16

val offWindowData1: Long = 20

val offWindowData2: Long = 24

val offKeyScancode: Long = 24

val offKeyKey: Long = 28

val offKeyMod: Long = 32

val offKeyDown: Long = 36

val offKeyRepeat: Long = 37

val offTextPointer: Long = 24

val offMotionX: Long = 28

val offMotionY: Long = 32

val offMotionDx: Long = 36

val offMotionDy: Long = 40

val offButtonButton: Long = 24

val offButtonClicks: Long = 26

val offButtonX: Long = 28

val offButtonY: Long = 32

val offWheelX: Long = 24

val offWheelY: Long = 28

@library("c")
@unsafe_ffi
extern func memcpyToFloat(dst: NativePtr[Float], src: NativePtr[Byte], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyFromFloat(dst: NativePtr[Byte], src: NativePtr[Float], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyToLong(dst: NativePtr[Long], src: NativePtr[NativePtr[Byte]], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyToPtr(dst: NativePtr[NativePtr[Byte]], src: NativePtr[Long], n: Long): NativePtr[Byte] = "memcpy"

@library("SDL3")
@unsafe_ffi
extern func SDL_PutAudioStreamDataFloats(stream: NativePtr[Byte], buf: NativePtr[Float], len: Int): Byte = "SDL_PutAudioStreamData"

@unsafe_ffi
func ptrToLong(p: NativePtr[Byte]): Long {
  var src = p
  var dst: Long = 0
  val _ = memcpyToLong(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@unsafe_ffi
func longToPtr(v: Long): NativePtr[Byte] {
  var src = v
  var dst: NativePtr[Byte] = nativeNullPtr()
  val _ = memcpyToPtr(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@unsafe_ffi
func readByte(base: Long, off: Long): Long {
  nativeLoadByte(longToPtr(base), off).toLong()
}

@unsafe_ffi
func readU16(base: Long, off: Long): Long {
  readByte(base, off).or(readByte(base, off + 1).shl(8))
}

@unsafe_ffi
func readU32(base: Long, off: Long): Long {
  readU16(base, off).or(readU16(base, off + 2).shl(16))
}

@unsafe_ffi
func readI32(base: Long, off: Long): Int {
  readU32(base, off).toInt()
}

@unsafe_ffi
func readF32(base: Long, off: Long): Float {
  var value: Float = 0.0f32
  val _ = memcpyToFloat(nativeAddrOf(value), longToPtr(base + off), 4)
  value
}

@unsafe_ffi
func writeByte(base: Long, off: Long, v: Long): Unit {
  nativeStoreByte(longToPtr(base), off, v.toByte())
}

@unsafe_ffi
func writeU32(base: Long, off: Long, v: Long): Unit {
  writeByte(base, off, v.and(255))
  writeByte(base, off + 1, v.shr(8).and(255))
  writeByte(base, off + 2, v.shr(16).and(255))
  writeByte(base, off + 3, v.shr(24).and(255))
}

@unsafe_ffi
func writeF32(base: Long, off: Long, v: Float): Unit {
  var value = v
  val _ = memcpyFromFloat(longToPtr(base + off), nativeAddrOf(value), 4)
}

/// SDL's description of the last failure.
@unsafe_ffi
pub func lastError(): String {
  match Ffi.tryFromCString(SDL_GetError()) {
    case Some(text) -> text
    case None -> "unknown SDL error"
  }
}

/// Starts SDL with the given subsystems (`initVideo`, `initAudio`, or their sum).
@unsafe_ffi
pub func init(subsystems: Int): Result[Unit, String] {
  if SDL_Init(subsystems + initEvents) == 0u8 {
    Err(error = "SDL_Init failed: " + lastError())
  } else {
    Ok(value = ())
  }
}

/// Shuts SDL down; windows and audio outputs still open are destroyed with it.
@unsafe_ffi
pub func quit(): Unit {
  SDL_Quit()
}

/// A window of `width` by `height` units.  It is hidden until `show`, so an application can
/// set up before anything appears.
@unsafe_ffi
pub func createWindow(title: String, width: Int, height: Int, resizable: Bool): Result[Window, String] {
  val name = Ffi.toCString(title)
  val flags = windowHidden + windowHighPixelDensity + (if resizable then windowResizable else 0)
  val handle = SDL_CreateWindow(name, width, height, flags)
  Ffi.release(name)
  if ptrToLong(handle) == 0 {
    Err(error = "SDL_CreateWindow failed: " + lastError())
  } else {
    Ok(value = Window(handle = ptrToLong(handle), id = SDL_GetWindowID(handle)))
  }
}

@unsafe_ffi
pub func destroyWindow(w: Window): Unit {
  SDL_DestroyWindow(longToPtr(w.handle))
}

@unsafe_ffi
pub func show(w: Window): Unit {
  val _ = SDL_ShowWindow(longToPtr(w.handle))
}

@unsafe_ffi
pub func hide(w: Window): Unit {
  val _ = SDL_HideWindow(longToPtr(w.handle))
}

@unsafe_ffi
pub func setTitle(w: Window, title: String): Unit {
  val name = Ffi.toCString(title)
  val _ = SDL_SetWindowTitle(longToPtr(w.handle), name)
  Ffi.release(name)
}

@unsafe_ffi
pub func setSize(w: Window, width: Int, height: Int): Unit {
  val _ = SDL_SetWindowSize(longToPtr(w.handle), width, height)
}

/// The window's size in the window system's units.
@unsafe_ffi
pub func windowSize(w: Window): Size {
  var width = 0
  var height = 0
  val _ = SDL_GetWindowSize(longToPtr(w.handle), nativeAddrOf(width), nativeAddrOf(height))
  Size(width = width, height = height)
}

/// The window's size in pixels, which a GPU surface is configured with.
@unsafe_ffi
pub func pixelSize(w: Window): Size {
  var width = 0
  var height = 0
  val _ = SDL_GetWindowSizeInPixels(longToPtr(w.handle), nativeAddrOf(width), nativeAddrOf(height))
  Size(width = width, height = height)
}

/// Pixels per unit of `windowSize`, for example 2.0 on a high-density display.
@unsafe_ffi
pub func displayScale(w: Window): Float {
  SDL_GetWindowDisplayScale(longToPtr(w.handle))
}

@unsafe_ffi
func pointerProperty(props: Int, name: String): Long {
  val key = Ffi.toCString(name)
  val value = ptrToLong(SDL_GetPointerProperty(props, key, nativeNullPtr()))
  Ffi.release(key)
  value
}

@unsafe_ffi
func numberProperty(props: Int, name: String): Long {
  val key = Ffi.toCString(name)
  val value = SDL_GetNumberProperty(props, key, 0)
  Ffi.release(key)
  value
}

/// The window system's own handles for the window, which a GPU surface needs.
@unsafe_ffi
pub func nativeWindow(w: Window): NativeWindow {
  val props = SDL_GetWindowProperties(longToPtr(w.handle))
  val x11Window = numberProperty(props, "SDL.window.x11.window")
  if x11Window != 0 {
    return X11(display = pointerProperty(props, "SDL.window.x11.display"), window = x11Window)
  }
  val waylandSurface = pointerProperty(props, "SDL.window.wayland.surface")
  if waylandSurface != 0 {
    return Wayland(display = pointerProperty(props, "SDL.window.wayland.display"), surface = waylandSurface)
  }
  val cocoa = pointerProperty(props, "SDL.window.cocoa.window")
  if cocoa != 0 {
    return Cocoa(window = cocoa)
  }
  val hwnd = pointerProperty(props, "SDL.window.win32.hwnd")
  if hwnd != 0 {
    return Win32(hwnd = hwnd, instance = pointerProperty(props, "SDL.window.win32.instance"))
  }
  Unavailable
}

@unsafe_ffi
func decode(cell: Long): Event {
  val kind = readU32(cell, 0)
  val window = readI32(cell, offWindowId)
  if kind == eventQuit {
    return Quit
  }
  if kind == eventWindowCloseRequested {
    return WindowCloseRequested(window = window)
  }
  if kind == eventWindowResized {
    return WindowResized(window = window, width = readI32(cell, offWindowData1), height = readI32(cell, offWindowData2))
  }
  if kind == eventKeyDown {
    return KeyDown(
      window = window,
      key = readI32(cell, offKeyKey),
      scancode = readI32(cell, offKeyScancode),
      modifiers = readU16(cell, offKeyMod).toInt(),
      repeat = readByte(cell, offKeyRepeat) != 0
    )
  }
  if kind == eventKeyUp {
    return KeyUp(
      window = window,
      key = readI32(cell, offKeyKey),
      scancode = readI32(cell, offKeyScancode),
      modifiers = readU16(cell, offKeyMod).toInt()
    )
  }
  if kind == eventTextInput {
    val text = match Ffi.tryFromCString(longToPtr(readU64(cell, offTextPointer))) { case Some(s) -> s; case None -> "" }
    return TextInput(window = window, text = text)
  }
  if kind == eventMouseMotion {
    return MouseMotion(
      window = window,
      x = readF32(cell, offMotionX),
      y = readF32(cell, offMotionY),
      dx = readF32(cell, offMotionDx),
      dy = readF32(cell, offMotionDy)
    )
  }
  if kind == eventMouseButtonDown {
    return MouseButtonDown(
      window = window,
      button = readByte(cell, offButtonButton).toInt(),
      x = readF32(cell, offButtonX),
      y = readF32(cell, offButtonY),
      clicks = readByte(cell, offButtonClicks).toInt()
    )
  }
  if kind == eventMouseButtonUp {
    return MouseButtonUp(
      window = window,
      button = readByte(cell, offButtonButton).toInt(),
      x = readF32(cell, offButtonX),
      y = readF32(cell, offButtonY),
      clicks = readByte(cell, offButtonClicks).toInt()
    )
  }
  if kind == eventMouseWheel {
    return MouseWheel(window = window, dx = readF32(cell, offWheelX), dy = readF32(cell, offWheelY))
  }
  Other(kind = kind.toInt())
}

@unsafe_ffi
func readU64(base: Long, off: Long): Long {
  readU32(base, off).or(readU32(base, off + 4).shl(32))
}

/// The next queued event, or None when there is none.  Pumps the window system first.
@unsafe_ffi
pub func pollEvent(): Option[Event] {
  val cell = Ffi.allocate(eventBufferSize)
  val got = SDL_PollEvent(cell) != 0u8
  val result = if got then Some(value = decode(ptrToLong(cell))) else None
  Ffi.release(cell)
  result
}

/// Waits up to `timeoutMs` for an event.
@unsafe_ffi
pub func waitEvent(timeoutMs: Int): Option[Event] {
  val cell = Ffi.allocate(eventBufferSize)
  val got = SDL_WaitEventTimeout(cell, timeoutMs) != 0u8
  val result = if got then Some(value = decode(ptrToLong(cell))) else None
  Ffi.release(cell)
  result
}

@unsafe_ffi
func clearCell(cell: Long): Unit {
  var i: Long = 0
  while i < eventBufferSize {
    writeByte(cell, i, 0)
    i = i + 1
  }
}

/// Queues `e` as if the window system had produced it: for tests, and to wake a loop.
/// Quit, key and mouse events can be posted.  SDL drops pushed window events (they belong to
/// the window system) and a text event carries a pointer, so those cannot be.
@unsafe_ffi
pub func post(e: Event): Result[Unit, String] {
  val cellPtr = Ffi.allocate(eventBufferSize)
  val cell = ptrToLong(cellPtr)
  clearCell(cell)
  var encoded = true
  match e {
    case Quit -> writeU32(cell, 0, eventQuit)
    case KeyDown(window, key, scancode, modifiers, repeat) -> {
      writeU32(cell, 0, eventKeyDown)
      writeU32(cell, offWindowId, window.toLong())
      writeU32(cell, offKeyScancode, scancode.toLong())
      writeU32(cell, offKeyKey, key.toLong())
      writeByte(cell, offKeyMod, modifiers.toLong().and(255))
      writeByte(cell, offKeyMod + 1, modifiers.toLong().shr(8).and(255))
      writeByte(cell, offKeyDown, 1)
      writeByte(cell, offKeyRepeat, if repeat then 1 else 0)
    }
    case KeyUp(window, key, scancode, modifiers) -> {
      writeU32(cell, 0, eventKeyUp)
      writeU32(cell, offWindowId, window.toLong())
      writeU32(cell, offKeyScancode, scancode.toLong())
      writeU32(cell, offKeyKey, key.toLong())
      writeByte(cell, offKeyMod, modifiers.toLong().and(255))
      writeByte(cell, offKeyMod + 1, modifiers.toLong().shr(8).and(255))
    }
    case MouseMotion(window, x, y, dx, dy) -> {
      writeU32(cell, 0, eventMouseMotion)
      writeU32(cell, offWindowId, window.toLong())
      writeF32(cell, offMotionX, x)
      writeF32(cell, offMotionY, y)
      writeF32(cell, offMotionDx, dx)
      writeF32(cell, offMotionDy, dy)
    }
    case MouseButtonDown(window, button, x, y, clicks) -> {
      writeU32(cell, 0, eventMouseButtonDown)
      writeU32(cell, offWindowId, window.toLong())
      writeByte(cell, offButtonButton, button.toLong())
      writeByte(cell, offButtonButton + 1, 1)
      writeByte(cell, offButtonClicks, clicks.toLong())
      writeF32(cell, offButtonX, x)
      writeF32(cell, offButtonY, y)
    }
    case MouseButtonUp(window, button, x, y, clicks) -> {
      writeU32(cell, 0, eventMouseButtonUp)
      writeU32(cell, offWindowId, window.toLong())
      writeByte(cell, offButtonButton, button.toLong())
      writeByte(cell, offButtonClicks, clicks.toLong())
      writeF32(cell, offButtonX, x)
      writeF32(cell, offButtonY, y)
    }
    case MouseWheel(window, dx, dy) -> {
      writeU32(cell, 0, eventMouseWheel)
      writeU32(cell, offWindowId, window.toLong())
      writeF32(cell, offWheelX, dx)
      writeF32(cell, offWheelY, dy)
    }
    case _ -> {
      encoded = false
    }
  }
  var outcome: Result[Unit, String] = Err(error = "this kind of event cannot be posted")
  if encoded {
    outcome = if SDL_PushEvent(cellPtr) != 0u8 then Ok(value = ()) else Err(error = "SDL_PushEvent failed: " + lastError())
  }
  Ffi.release(cellPtr)
  outcome
}

/// Text events are delivered for `w` until `stopTextInput`.
@unsafe_ffi
pub func startTextInput(w: Window): Unit {
  val _ = SDL_StartTextInput(longToPtr(w.handle))
}

@unsafe_ffi
pub func stopTextInput(w: Window): Unit {
  val _ = SDL_StopTextInput(longToPtr(w.handle))
}

/// The clipboard's text, or None when it holds none.
@unsafe_ffi
pub func clipboardText(): Option[String] {
  if SDL_HasClipboardText() == 0u8 {
    return None
  }
  val raw = SDL_GetClipboardText()
  val text = Ffi.tryFromCString(raw)
  SDL_free(raw)
  text
}

@unsafe_ffi
pub func setClipboardText(text: String): Result[Unit, String] {
  val c = Ffi.toCString(text)
  val ok = SDL_SetClipboardText(c) != 0u8
  Ffi.release(c)
  if ok then Ok(value = ()) else Err(error = "SDL_SetClipboardText failed: " + lastError())
}

/// Nanoseconds since SDL started.
@unsafe_ffi
pub func nowNanos(): Long {
  SDL_GetTicksNS()
}

/// A high-resolution counter and its ticks per second, for measuring intervals.
@unsafe_ffi
pub func counter(): Long {
  SDL_GetPerformanceCounter()
}

@unsafe_ffi
pub func counterFrequency(): Long {
  SDL_GetPerformanceFrequency()
}

@unsafe_ffi
pub func delayNanos(ns: Long): Unit {
  SDL_DelayNS(ns)
}

/// Opens the default playback device for `channels` channels of 32-bit float samples at
/// `frequency` Hz, and starts it.
@unsafe_ffi
pub func openAudio(frequency: Int, channels: Int): Result[Audio, String] {
  var spec = SDL_AudioSpec(format = SDL_AUDIO_F32, channels = channels, freq = frequency)
  val device = SDL_OpenAudioDevice(defaultPlaybackDevice, nativeAddrOf(spec))
  if device == 0 {
    return Err(error = "SDL_OpenAudioDevice failed: " + lastError())
  }
  val stream = SDL_CreateAudioStream(nativeAddrOf(spec), nativeAddrOf(spec))
  if ptrToLong(stream) == 0 {
    SDL_CloseAudioDevice(device)
    return Err(error = "SDL_CreateAudioStream failed: " + lastError())
  }
  if SDL_BindAudioStream(device, stream) == 0u8 {
    SDL_DestroyAudioStream(stream)
    SDL_CloseAudioDevice(device)
    return Err(error = "SDL_BindAudioStream failed: " + lastError())
  }
  val _ = SDL_ResumeAudioDevice(device)
  Ok(value = Audio(device = device, stream = ptrToLong(stream), channels = channels, frequency = frequency))
}

/// Queues interleaved samples (`channels` per frame) for playback.
@unsafe_ffi
pub func queueSamples(a: Audio, samples: buffer[Float]): Result[Unit, String] {
  val bytes = samples.length * 4
  val ok = samples.withPointer({ p: NativePtr[Float] -> SDL_PutAudioStreamDataFloats(longToPtr(a.stream), p, bytes) })
  if ok != 0u8 then Ok(value = ()) else Err(error = "SDL_PutAudioStreamData failed: " + lastError())
}

/// Bytes queued and not yet played.
@unsafe_ffi
pub func queuedBytes(a: Audio): Int {
  SDL_GetAudioStreamQueued(longToPtr(a.stream))
}

/// Tells the stream no more samples are coming for now, so the tail is played out.
@unsafe_ffi
pub func flushAudio(a: Audio): Unit {
  val _ = SDL_FlushAudioStream(longToPtr(a.stream))
}

@unsafe_ffi
pub func closeAudio(a: Audio): Unit {
  SDL_DestroyAudioStream(longToPtr(a.stream))
  SDL_CloseAudioDevice(a.device)
}
