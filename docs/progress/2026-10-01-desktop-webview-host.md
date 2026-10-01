# Desktop webview host (docs/65 U5, D162)

`Ui.Host.Desktop` opens an application in a system webview window on
`--target dotnet` and `--target jvm`.

- **Design.**
  - The web host is served on `127.0.0.1`, on a free port, from a
    background thread. The window, on the main thread, loads it through
    a local loader page that waits for the server.
  - No callback crosses the C boundary. The `webview` 0.12.0 library is
    bound with `@library` (D158), and C strings come from `Std.Ffi`
    (D161).
  - Closing the window, or calling `Desktop.close()`, ends the program.
- **Access token.**
  - `HostConfig.accessToken`, when set, admits only clients that present
    it. The first request's `_access` query parameter is traded for an
    `HttpOnly`, `SameSite=Lax` cookie and a redirect.
  - Later pages and the session socket need the cookie. Without it, a
    page gets `403` and a socket is closed on open.
  - The desktop host sets a fresh random token for each run.
- **Library install.**
  - `scripts/ci/install-webview.sh` builds webview 0.12.0 (pinned tag and
    commit) as `libwebview.so` on WebKitGTK 4.1.
  - webview 0.12.0's GTK `webview_set_size` reports an error after
    applying the size, so that one result is ignored.
- **Example.** `examples/ui-customers` opens in a window with
  `-- --desktop`.
- **Compiler fixes found on the way.**
  - `NativePtr` equality (`p == nativeNullPtr()`) lowered to
    `Object.Equals` on MSIL (invalid IL). It is now `ceq`.
  - The method form of `isSome`/`isNone`/`isOk`/`isErr` (`o.isNone()`)
    lowered to an instance call on the `Option`/`Result` interface on the
    JVM (`IncompatibleClassChangeError`) and was rejected on MSIL. Both
    backends now lower it like the field form. This is pinned in
    `map_option_self_test.l` on both targets.
- **Tests.**
  - `lyric-ui/tests/desktop_tests.l`: the token guard through the router,
    cookie parsing, the loader page and `jsString`.
  - `scripts/ci/ui-desktop-e2e.sh` runs `lyric-ui/e2e/desktop-probe` in a
    real window under Xvfb on dotnet and the JVM. It passes only when the
    runtime in the window has connected its session and reported its data
    grid's viewport.
- **Native.**
  - Not yet: the host is the web host, which needs `lyric-web` and
    `lyric-ws` on native (#7990).
  - A fully native renderer is docs/67 G10 (#7949).
