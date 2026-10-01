# D152 — Prerendered first paint: the page request starts the session

**Status:** accepted, implemented

Implements docs/65 §13.4 (the first slice of phase U6).

## Context

The web host served an empty shell; nothing appeared until the runtime
loaded, opened the WebSocket and received the first patch. §13.4 asks for
the first view in the HTML.

Rendering a view needs a session: a screen's first view comes from `init`.
Rendering it at page time in a throwaway session, and then starting the
real session over the socket, would run `init` and its effects (loads,
writes) twice.

## Decision

1. **The page request starts the session.** The shell handler routes the
   requested URL and admits a new session with no connection, as a
   disconnected session. `admit` with an empty connection id binds none.
   It starts the instance with an outbox that follows the session.
   It takes `Instance.snapshot()`, the current tree as HTML, and then
   detaches it.
2. **The socket resumes it.** The shell carries the id as `data-sid`; the
   runtime quotes it in its first `hello`, and the existing resume path
   (D138, Q-UI-007) sends the whole tree. Effects started at page time
   keep running. While the session is detached their results update the
   model only, and the resume renders whatever state they reached.
3. **`Ui.Html` renders `WireNode`s exactly as the runtime's `DomRenderer`
   builds them:**
   - the same elements, classes, roles, `aria-*` and `data-*` attributes;
   - field/label/error wiring, the selected option, and inert controls;
   - ids numbered `lui-s1...` in document order.

   The resume's replace of the root swaps the markup without a visible
   change.
4. **The page is inert until live.** The runtime now clears `aria-busy` on
   the mount when the first patch is applied, not when the socket opens.
5. **Prerendered pages are not cached** (`Cache-Control: no-store`): each
   names a session.
6. **Unclaimed sessions** (the browser never connects, or a crawler)
   expire after `reconnectGraceMs` and count toward `maxSessions` like
   disconnected sessions. At capacity, the page is served unrendered and
   the socket gets the "server busy" page as before.
7. **The URL is rebuilt.** `Request` has no raw query, so the shell
   rebuilds it from the parsed parameters, percent-encoded; parameter
   order may differ from what the browser sent.
8. **`HostConfig.prerender`** (default `true`) turns it off.

## Consequences

- `HostConfig` gains `prerender`, `Instance` gains `snapshot`, and
  `shellHtml` takes the session id and the first view.
- Each page request does the work of starting a screen; for a server that
  cannot afford a session per unclaimed page load, set `prerender = false`.
