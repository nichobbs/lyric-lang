# lyric-ui

A model-view-update UI library for Lyric: one application model for desktop
and web (`docs/65-ui-library-sketch.md`, D137).

Status: **experimental, phases U1 to U4 and part of U6.** The pure core,
the session driver, the server-driven web host with a prerendered first
paint (D152), the `[layers]` checker (D149) and the form and route
generators (D151) are implemented and tested; `Lazy` subtrees, the data
grid, and the desktop and WASM hosts are planned (docs/65 §14).

## The application model

A screen is a set of pure functions plus an effect interpreter:

```lyric
pub func init(id: in CustomerId): Step[Model, Effect]
pub func update(m: in Model, msg: in Msg): Step[Model, Effect]   // pure, deterministic
pub func view(m: in Model): View[Msg]                             // pure
pub async func run(e: in Effect, repo: in CustomerRepository): Option[Msg]   // the only I/O
```

Effects are returned as **data**, so a test asserts on exactly what the
screen asked for. Navigation, confirmation dialogs and toasts are
`UiEffect`s the runtime interprets itself. See `examples/ui-customers/` for
a complete screen split across domain, ports, logic, effects and view
packages, with its tests.

## Packages

| Package | Layer | Contents |
|---|---|---|
| `Ui.Core` | logic, view | `View`, `Handler`, `Step`, `UiEffect`, `mapView` |
| `Ui.Widgets` | view | typed builders for the semantic widget set |
| `Ui.Forms` | view | renders a `Forms.FormSchema` as fields |
| `Ui.Routing` | logic, effects, view | URL path splitting and percent encoding for typed routes |
| `Ui.Html` | runtime | a rendered view as HTML, for the prerendered first paint |
| `Ui.Testing` | tests | queries over `View` values: `click`, `typeInto`, `fieldErrors`, `hasText` |
| `Ui.Diff` | runtime | view diffing, patches, and the reference patch applier |
| `Ui.Protocol` | runtime | the JSON wire format between session and host |
| `Ui.Session` | runtime | the pure session step functions and `Program` |
| `Ui.Host` | runtime | the host-independent session driver (`instance`, `Outbox`) |
| `Ui.Host.Web` | app | server-driven web host over `lyric-web` + `lyric-ws` |
| `Ui.Host.Assets` | runtime | the embedded TypeScript runtime and theme (generated) |

## Typed routes

`Ui.Routes` (`routes/`, D151) is a source generator that derives
`parseRoute(url)` and `routeUrl(r)` from a union whose cases carry `@path`:

```lyric
@generate(Ui.Routes)
pub union Route {
  @path("/customers") case CustomerList
  @path("/customers/{id:Long}") case EditCustomer(id: CustomerId)
}
```

- **Segments:** each `{field}` segment binds a case field; `{field:Long}`
  (or `:Int`, `:String`) names the segment's type for a distinct type
  declared in another file.
- **Matching:** cases are tried in order, and the query and fragment are
  ignored.
- **Diagnostics:** `RT001`–`RT006`.

Declare `"Ui.Routes" = { path = "../lyric-ui/routes" }` beside `Lyric.Ui`.

## Widgets

Layout `column`, `row`, `card`, `section`; text `heading`, `paragraph`,
`badge`, `showIf`; feedback `banner`, `spinner`; actions `button`, `primaryButton`,
`buttonWith`, `link`; forms `form`, `field`, `textInput`, `textArea`,
`numberInput`, `checkbox`, `select`; data `table`, `tableRow`. Use `keyed`
on items of dynamic lists so reorders patch as moves.

## Serving a web application

```lyric
import Ui.Host.{Instance, instance}
import Ui.Host.Web as WebHost

func route(url: in String): Option[Instance] { ... }   // URL -> screen instance

func main(): Unit {
  match WebHost.serve(WebHost.defaultConfig("Customers"), route) {
    case Ok(_) -> ()
    case Err(e) -> Console.error(e)
  }
}
```

The page, its assets and the session WebSocket (at `wsPath`, default
`/_ui`) are all served on `port` (default 8080). `WebHost.router(cfg, route)`
returns the same thing as a `lyric-web` router, to merge into an
application's own routes (merge it last: its shell matches every path).

The effects of a step run concurrently, each on its own task, and their
result messages are applied one at a time in the order they finish, so a
slow effect does not hold up the others or the user's input (#7835).

A session survives a dropped connection: the browser reconnects with the
session id it was given and resumes where it left off, within
`reconnectGraceMs` (default two minutes). A disconnected session keeps only
its model. `maxSessions` (default 10000) bounds the sessions in memory; when
it is reached, the longest-disconnected sessions are evicted first
(docs/65 §9.5, §10.1, D138).

The session id is a bearer credential: anyone who obtains it can take over
the session within the grace period. Serve the page and socket over TLS in
production. The host itself speaks plain HTTP and `ws`, so put a
TLS-terminating proxy in front of it; when the proxy sends
`X-Forwarded-Proto: https` the page opens a `wss` socket on the same host
and port. If the proxy exposes the socket somewhere else (for example
on port 443 under `/_ui`), set `publicWsUrl` to that URL:

```lyric
val cfg = WebHost.defaultConfig("Customers").copy(publicWsUrl = "wss://app.example.com/_ui")
```

Keyed nodes (`keyed(key, view)`) are addressed by key in events, so a click
on a row that moved between render and click still reaches that row, and a
click on a row that has gone is dropped. Key the items of dynamic lists.

## Host runtime (TypeScript)

`runtime/` holds the browser/webview runtime: it applies patches to a
mirror tree (`tree.ts`), renders the semantic widgets (`render.ts`) and
talks to the session (`main.ts`). It is the one accepted non-Lyric
component of the UI stack (D137) and carries no application logic.

```sh
cd lyric-ui/runtime
npm run build           # tsc -> dist/
npm test                # mirror-tree patch semantics under node --test
node embed.mjs          # regenerate src/host_assets.l from dist/ and ui.css
node embed.mjs --check  # verify host_assets.l is up to date
```

## Tests

```sh
lyric test --manifest lyric-ui/lyric.toml
lyric test --manifest lyric-ui/routes/lyric.toml   # the route generator
```
