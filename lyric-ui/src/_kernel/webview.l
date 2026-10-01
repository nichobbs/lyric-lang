//! lyric-ui/src/_kernel/webview.l — the C `webview` library (docs/65 §10.2).
//!
//! Binds webview 0.12 (https://github.com/webview/webview), built as the
//! shared library `libwebview` over WebKitGTK on Linux, WebKit on macOS and
//! WebView2 on Windows (`scripts/ci/install-webview.sh` builds it on Linux).
//! The `@library` bindings (D158) and `Std.Ffi` C strings (D161) serve
//! every target from this one file.
//!
//! The desktop host is the only caller: it opens one window and blocks in
//! `runWindow` until the window closes.  The C library requires that thread
//! to be the one that created the window, and on macOS the main thread, so
//! `runWindow` is called from the program's main thread.
//!
//! Internal: only Ui.Host.Desktop should import this.
@axiom("webview 0.12's C API conforms to its webview.h documentation; webview_terminate may be called from any thread")
@io
package Ui.Kernel.Webview

import Std.Core
import Std.Ffi as Ffi
import Std.Task as Task
import Std.Time as Time

@library("webview")
extern func wvCreate(debug: Int, window: NativePtr[Byte]): NativePtr[Byte] = "webview_create"

@library("webview")
extern func wvDestroy(w: NativePtr[Byte]): Int = "webview_destroy"

@library("webview")
extern func wvRun(w: NativePtr[Byte]): Int = "webview_run"

@library("webview")
extern func wvTerminate(w: NativePtr[Byte]): Int = "webview_terminate"

@library("webview")
extern func wvSetTitle(w: NativePtr[Byte], title: NativePtr[Byte]): Int = "webview_set_title"

@library("webview")
extern func wvSetSize(w: NativePtr[Byte], width: Int, height: Int, hints: Int): Int = "webview_set_size"

@library("webview")
extern func wvSetHtml(w: NativePtr[Byte], html: NativePtr[Byte]): Int = "webview_set_html"

/// What to open: a window titled `title` of `width` by `height` pixels
/// showing the document `html`.  `devTools` enables the browser's
/// developer tools.
pub record WindowSpec {
  title: String
  width: Int
  height: Int
  html: String
  devTools: Bool
  invariant: width > 0 and height > 0
}

/// Asks an open window to close, from any thread.
pub protected type CloseSignal {
  var requested: Bool = false
  var finished: Bool = false
  var watcherDone: Bool = false
  entry request(): Unit {
    requested = true
  }
  entry finish(): Unit {
    finished = true
  }
  entry watcherStopped(): Unit {
    watcherDone = true
  }
  func isRequested(): Bool {
    return requested
  }
  func isFinished(): Bool {
    return finished
  }
  func isWatcherStopped(): Bool {
    return watcherDone
  }
}

/// Opens the window described by `spec` and blocks until it closes, either
/// because the user closed it or because `close.request()` was called.
/// Returns why the window could not be opened.
@unsafe_ffi
pub func runWindow(spec: in WindowSpec, close: in CloseSignal): Result[Unit, String] {
  val w = wvCreate(if spec.devTools { 1 } else { 0 }, nativeNullPtr())
  if w == nativeNullPtr() {
    return Err(
      error = "could not create the window (webview_create failed; is a display available and WebKitGTK 4.1 installed?)"
    )
  }
  val title = Ffi.toCString(spec.title)
  val titled = wvSetTitle(w, title)
  Ffi.release(title)
  // WEBVIEW_HINT_NONE: the user may resize the window.  The result is not
  // checked: webview 0.12.0's GTK backend applies the size and then
  // returns WEBVIEW_ERROR_INVALID_ARGUMENT for every hint (its
  // `set_size_impl` falls through to the "Invalid hint" return), and
  // WEBVIEW_HINT_NONE is always a valid hint.
  val _ = wvSetSize(w, spec.width, spec.height, 0)
  val html = Ffi.toCString(spec.html)
  val shown = wvSetHtml(w, html)
  Ffi.release(html)
  if titled != 0 or shown != 0 {
    val _ = wvDestroy(w)
    return Err(
      error = "could not set up the window (webview error " + (if titled != 0 { titled } else { shown }).toString() +
        ")"
    )
  }
  // webview_terminate is the one call the library allows from another
  // thread, so a watcher relays a close request to the window.  The window
  // is destroyed only once the watcher has stopped, so a request that
  // arrives as the window closes never reaches a destroyed window.
  val watchers = Task.makeScope()
  Task.scopeSpawn(
    watchers,
    { ->
      var sent = false
      while not close.isFinished() {
        if not sent and close.isRequested() {
          val _ = wvTerminate(w)
          sent = true
        }
        Time.sleepMillis(50)
      }
      close.watcherStopped()
    }
  )
  val ran = wvRun(w)
  close.finish()
  while not close.isWatcherStopped() {
    Time.sleepMillis(10)
  }
  val _ = wvDestroy(w)
  if ran != 0 {
    return Err(error = "the window's event loop failed (webview error " + ran.toString() + ")")
  }
  return Ok(value = ())
}
