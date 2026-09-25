# lyric-ui

A model-view-update UI library for Lyric: one application model for desktop
and web (`docs/65-ui-library-sketch.md`, D137).

Status: **experimental, phases U1 and U2.** The pure core, the session
driver and the server-driven web host are implemented and tested; the
`[layers]` checker, form and route generators, desktop and WASM hosts are
planned (docs/65 §14).

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
| `Ui.Testing` | tests | queries over `View` values: `click`, `typeInto`, `fieldErrors`, `hasText` |
| `Ui.Diff` | runtime | view diffing, patches, and the reference patch applier |
| `Ui.Protocol` | runtime | the JSON wire format between session and host |
| `Ui.Session` | runtime | the pure session step functions and `Program` |
| `Ui.Host` | runtime | the host-independent session driver (`instance`, `Outbox`) |
| `Ui.Host.Web` | app | server-driven web host over `lyric-web` + `lyric-ws` |
| `Ui.Host.Assets` | runtime | the embedded TypeScript runtime and theme (generated) |

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

HTTP is served on `port` (default 8080) and the session WebSocket on
`wsPort` (default 8081), because `lyric-ws` runs its own listener.

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
```
