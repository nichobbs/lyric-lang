# D162 — The desktop webview host: a loopback page server in a webview window

**Status:** accepted, implemented (.NET and JVM)

docs/65 phase U5 (§10.2). Builds on D158 (`@library` C bindings) and D161
(C strings).

## Context

docs/65 §10.2 planned the desktop host as "the same protocol over an
in-process channel to a system webview". An in-process channel means the
webview's JavaScript calls into Lyric and Lyric pushes patches into the
page: `webview_bind` and `webview_eval`, both of which deliver their work
through C callbacks into the host program. The managed targets cannot pass
a Lyric function to C as a callback yet (D158 admits scalars and pointers
only), and the web host already implements the whole session protocol over
a WebSocket.

## Decision

1. **The window shows the web host, served on the loopback interface.**
   `Ui.Host.Desktop.run(cfg, route)` builds the `Ui.Host.Web` router for
   `route`, serves it on `127.0.0.1` on a background thread
   (`Std.Task.scopeSpawn`), and opens a webview window on the main thread
   that loads it. Screens, runtime and protocol are the web host's, so an
   application behaves the same in a browser and in a window. No callback
   crosses the C boundary: the only C calls are create, set title, set
   size, set HTML, run, terminate and destroy.
2. **Only the window is admitted.** A loopback port is reachable by every
   program on the machine, so `HostConfig` gains `accessToken`. The desktop
   host sets it to 32 fresh random bytes each run and gives it to the
   window alone, as the `_access` query parameter of the first URL. The
   web host trades a valid token for an `HttpOnly`, `SameSite=Lax` cookie
   and a redirect that drops it from the URL; later page requests and the
   session socket must carry the cookie, and get `403` (a socket is closed
   on open) without it. Tokens are compared in constant time. `Lax`
   rather than `Strict` because the first navigation starts on the
   loader page (item 3), another origin, and browsers withhold a `Strict`
   cookie from the redirect that ends such a navigation. The runtime's
   JavaScript and CSS are not guarded: they are the same for every
   application. A web host's `accessToken` defaults to empty, which admits
   every client as before.
3. **A loader page hides start-up.** The window first shows a local page
   that polls the server and replaces itself with the application once the
   server answers, so the window appears at once and never shows a
   connection error while the server binds. After 15 seconds without an
   answer it says the server could not start.
4. **The port is chosen free, on loopback.** `port = 0` (the default)
   picks a random port in the dynamic range on which a listener can be
   bound, trying up to 32.
5. **Closing the window ends the program.** `run` returns `Never`: exit
   status 0 when the window closes, 1 (with the reason on standard error)
   when the window or the server cannot start. `Desktop.close()` closes the
   window from any thread, typically from a "Quit" effect. A watcher thread
   relays it with `webview_terminate`, the one call the library allows from
   another thread, and the window is destroyed only after the watcher has
   stopped. Ending the process is the only way to stop the page server on
   both targets (the JVM listener's threads keep the process alive).
6. **The library is installed by the user, pinned in CI.** The host binds
   `@library("webview")`, webview 0.12.0 built as a shared library.
   `scripts/ci/install-webview.sh` builds the pinned release (tag and
   commit) on WebKitGTK 4.1, and is the documented install route on Linux.
   webview 0.12.0's GTK backend reports an error from every
   `webview_set_size` after applying it, so that one result is not checked.
7. **Targets.** .NET and the JVM. The native target waits for `lyric-web`
   and `lyric-ws` to build there (and for native generic protected types,
   #7864), since the host is the web host (#7990); a fully native renderer is
   docs/67 G10 (#7949).

## Consequences

- An application gets a desktop build by calling `Desktop.run` instead of
  `WebHost.serve`; `examples/ui-customers` does so with `--desktop`.
- The in-process channel of §10.2's first plan is not needed for
  correctness. It would save the loopback hop, and can follow once C
  callbacks cross the managed boundary.
- Verified by `lyric-ui/tests/desktop_tests.l` (the token guard through
  the router, cookie parsing, the loader page) and by
  `scripts/ci/ui-desktop-e2e.sh`, which runs `lyric-ui/e2e/desktop-probe`
  in a real window under Xvfb on .NET and the JVM: the probe passes only
  when the runtime in the window has connected its session and reported
  its data grid's viewport.
