# 65 - UI library: one app model for desktop and web (sketch)

**Status:** Specced in D137. Phases U1 (pure core, `lyric-forms`, example)
and U2 (server-driven web host and TypeScript runtime) are implemented; see
§14 for the phase plan and §15 for what the first implementation surfaced
and how each finding was resolved. Open questions Q-UI-001 to Q-UI-011 are
in §16.

**Builds on:** `docs/35-js-wasm-component-sketch.md` (WASM target, future
client host), `docs/40-source-generators.md` (D075, the `@generate` API the
form generator uses), `docs/58-wire-templates-sketch.md` (D121, `wire`
composition), `docs/62-jsonrpc-mcp.md` (lyric-ws dotnet backend).

**Libraries:** `lyric-ui/` (`Ui.*`), `lyric-forms/` (`Forms.*`).
**Example:** `examples/ui-customers/`.

---

## 1. Motivation and scope

Lyric has a server story (`lyric-web`, `lyric-ws`, `lyric-grpc`) but no way
to build an interactive user interface. The target audience for a first UI
library is **line-of-business applications** (forms, lists, dashboards,
admin tools) that must run both as desktop applications and in a browser,
from a single codebase.

Goals:

1. One application model that is independent of where it is rendered.
2. Screen logic that is deterministic and testable with plain `lyric test`,
   with no browser, webview or mocking framework.
3. A separation between view code and functionality that the compiler
   enforces, not just a convention.
4. Forms derived from domain types, so validation rules (range subtypes,
   invariants) are written once.
5. Priority order of targets: native and MSIL first, JVM later.

Non-goals for v1: a native look and feel on each OS (nice to have, not
required), game-style rendering, and a public widget toolkit comparable to
WPF or Swing.

---

## 2. Decisions (D137)

| # | Question | Decision |
|---|---|---|
| 1 | Programming model | Model-view-update: `Model`, `Msg`, `update`, `view`, with effects returned as **data** (an `Effect` union per screen), not closures. |
| 2 | Separation of view and logic | **Enforced** by a general `[layers]` language feature (§5), shipped with a `ui` preset. The stdlib is classified `@pure` / `@io`. |
| 3 | Rendering | HTML/CSS through a small host runtime. |
| 4 | Where code runs (web) | Server-driven first (diffs over `lyric-ws`); client WASM later (§13.1). |
| 5 | Desktop | The same protocol, in process, rendered by a system webview. |
| 6 | Widget vocabulary | **Semantic widgets** (button, text input, data grid...) with a `raw` escape hatch for the web host only. |
| 7 | Browser runtime language | A small, audited **TypeScript runtime** is accepted as the one non-Lyric component (§10.3). |
| 8 | Embedded components | **Explicit nesting** first; `@generate(Embed)` is future work (§13.2). |

---

## 3. Architecture

```
  app code (target-neutral, pure):  Model, Msg, Effect, update, view
                               |
                 View tree -> diff -> Patch list          (Ui.View, Ui.Diff)
                               |
                 session loop: Msg queue, handler table   (Ui.Session)
                               |
         +---------------------+----------------------+
   Server-driven web      Desktop webview          Client WASM (future)
   patches over lyric-ws  in-process channel to    native backend -> wasm32,
   to the TS runtime      a system webview         patches applied locally
```

Every host consumes the same `Patch` list and produces the same `Event`
records. Application code only produces `View` values and `Effect` values,
so adding a host never changes application code.

### 3.1 Application layers

A screen is five packages. Each has one job, and the layer rules (§5)
decide what each may import.

```
customers/
  domain/customer.l        domain     types, invariants, rules        (no UI, no I/O)
  app/ports.l              ports      repository interfaces           (no UI)
  screens/edit/logic.l     logic      Model, Msg, Effect, update      (pure, no Ui widgets)
  screens/edit/effects.l   effects    Effect -> async Msg             (I/O, no Ui widgets)
  screens/edit/view.l      view       Model -> View[Msg]              (Ui only, no ports)
  main.l                   app        wire + host                     (everything meets here)
```

---

## 4. The application model

### 4.1 Screen logic

```lyric
pub union Msg {
  case Loaded(result: Result[Customer, String])
  case FieldEdited(field: CustomerField, value: String)
  case SaveClicked
  case Saved(result: Result[Customer, String])
  case CancelClicked
  case DiscardConfirmed
}

pub union Effect {
  case LoadCustomer(id: CustomerId)
  case SaveCustomer(customer: Customer)
  case Ui(effect: UiEffect[Msg])        // Navigate, Confirm, Toast (§6.3)
}

pub func init(id: in CustomerId): Step[Model, Effect]
pub func update(m: in Model, msg: in Msg): Step[Model, Effect]
```

`Step[M, E]` is a record `{ model: M, effects: List[E] }` with helpers
`Ui.Step.none(m)` and `Ui.Step.with(m, effects)`.

Why effects are data: an `Effect` value can be compared, logged, recorded
and replayed. A test asserts on exactly what the screen asked for. A
closure-based `Cmd` is opaque to tests. The cost is one union and one
interpreter per screen.

### 4.2 Effect interpreter

```lyric
pub async func run(e: in Effect, repo: in CustomerRepository): Msg?
```

The session runtime runs each effect concurrently under the session's
`scope` and queues the returned `Msg`. `UiEffect`s (navigation, dialogs,
toasts) are interpreted by the runtime itself; the screen interpreter
never sees them.

### 4.3 View

```lyric
pub func view(m: in Model): View[Msg]
```

The view says which message an event produces, never what it does.

### 4.4 What stays out of `Model`

Transient visual state (focus, hover, scroll offset, an open dropdown, the
caret position) lives in the host widget and never reaches `update`. The
rule: **`Model` holds only what the screen logic makes decisions on.** A
sort column that changes which rows are fetched is in `Model`; a sort that
only reorders visible rows belongs to the widget.

### 4.5 Determinism

`update` must be deterministic. Current time, fresh identifiers and random
numbers arrive through messages (`Tick(now)`, a `NewId` effect answered by
`IdIssued(id)`), never by calling `Std.Time.now()` from logic. The layer
rules enforce this (§5). As a result, a recorded list of messages replays a
session exactly, which is the basis for bug reproduction (§12.3).

---

## 5. Enforced layering (`[layers]`)

This is a **general** language feature, not specific to UI; the UI library
ships a preset.

### 5.1 Manifest

```toml
[layers]
preset = "ui"

[layers.packages]
"Customers.Domain"            = "domain"
"Customers.Ports"             = "ports"
"Customers.Screens.*.Logic"   = "logic"
"Customers.Screens.*.Effects" = "effects"
"Customers.Screens.*.View"    = "view"
```

A package may also declare its layer in source with `@layer("logic")`; the
manifest wins on conflict and a mismatch is a diagnostic. Custom presets
define their own layer names and matrix:

```toml
[layers.rules]
logic = { may_import = ["domain", "logic", "pure"], async = false }
```

### 5.2 The `ui` preset matrix

| Layer | May import | May not |
|---|---|---|
| `domain` | `domain`, `pure` | everything else |
| `ports` | `domain`, `pure` | `Ui.*`, `effects`, `view` |
| `logic` | `domain`, `logic`, `pure`, `Ui.Core` | `Ui` widgets, `ports`, `effects`, `io`; no `async func` |
| `effects` | `domain`, `logic`, `ports`, `pure`, `io`, `Ui.Core` | `Ui` widgets, `view` |
| `view` | `domain`, own `logic`, `pure`, `Ui.Core`, `Ui.Widgets` | `ports`, `effects`, `io`; no `async func` |
| unlayered (`app`) | anything | nothing |

`Ui.Core` holds only data types (`View`, `Step`, `UiEffect`, `Event`); it is
itself classified `pure`. `Ui.Widgets` is `pure` too (it builds values), but
is restricted to `view` by the preset so that logic cannot construct views.

### 5.3 Stdlib classification

Every stdlib package carries `@pure` or `@io` at package level. Mixed
modules are split or annotated per function:

| Package | Class | Notes |
|---|---|---|
| `Std.Core`, `Std.Collections`, `Std.String`, `Std.Char`, `Std.Math`, `Std.Json` (value model), `Std.Xml`, `Std.Yaml`, `Std.Format` | pure | |
| `Std.Time` | mixed | types and arithmetic pure; `now`, `nowEpochMillis` are `@io` |
| `Std.Uuid` | mixed | `parseUuidOpt`, `uuidToString` pure; `newUuid` `@io` |
| `Std.File`, `Std.Directory`, `Std.Http`, `Std.Process`, `Std.Environment`, `Std.Log`, `Std.Random` | io | |

A function-level `@io` inside a `@pure` package makes the package usable from
pure layers, and a call to that function from a pure layer is the error.

### 5.4 Diagnostics

| Code | Meaning |
|---|---|
| `Y0001` | Package in layer X imports a package in layer Y, which the matrix forbids. |
| `Y0002` | A restricted layer imports an unclassified package (neither layered nor `@pure`/`@io`). |
| `Y0003` | A restricted layer calls an `@io` function from a `@pure`-classified package. |
| `Y0004` | `async func` declared in a layer that forbids it. |
| `Y0005` | `@layer` annotation disagrees with the manifest. |
| `Y0006` | Unknown layer name or preset. |

### 5.5 Known gaps

Module-level mutable state and `protected type` instances reachable from a
pure layer would break determinism. Both should be rejected in `pure`,
`logic` and `view` layers by the same check (Q-UI-003).

---

## 6. Composition

Four separate problems, which Elm-style designs tend to conflate.

### 6.1 Pages: the router owns the wrapping

Each screen is a value. The application never writes a union that wraps
every screen's message type.

```lyric
pub record Screen[Params, Model, Msg, Effect] {
  init: (Params, Ctx) -> Step[Model, Effect]
  update: (Ctx, Model, Msg) -> Step[Model, Effect]
  view: (Ctx, Model) -> View[Msg]
  run: (Effect) -> async Msg?
  subscriptions: (Model) -> List[Sub[Msg]]
  canLeave: (Model) -> Bool
}
```

The runtime erases each active screen into an opaque `ActiveScreen` that
closes over its own model, so the router's state is homogeneous. Routes are
a union, so links are typed:

```lyric
@generate(Ui.Routes)
pub union Route {
  @path("/customers")        case CustomerList
  @path("/customers/{id}")   case EditCustomer(id: CustomerId)
}
// generated: parseRoute(url): Route?, routeUrl(r): String
// view: link("Edit", EditCustomer(c.id))   -- no hand-written URLs
```

The application maps each `Route` case to a `Screen` with an exhaustive
`match`, so a route without a screen is a compile error.

### 6.2 Embedded components: explicit nesting

A reusable component with business logic (a customer picker inside an order
form) returns a third list of **outcomes** that its parent interprets:

```lyric
// Picker
pub union Out { case Picked(customer: CustomerSummary)  case Dismissed }
pub func update(m: in Model, msg: in Msg): Nested[Model, Effect, Out]

// Parent
union Msg { case PickerMsg(msg: Picker.Msg) ... }
union Effect { case PickerFx(fx: Picker.Effect) ... }
// view: Ui.map(Picker.view(m.picker), PickerMsg)
```

This costs about ten lines per embedded component. Library widgets (date
picker, combo box, data grid) do **not** nest: their visual state lives in
the host, and they are used as `datePicker(value, onChange)`.

### 6.3 Dialogs, toasts and navigation are effects

```lyric
case CancelClicked ->
  if m.dirty then Step.with(m, [Ui(Confirm("Discard changes?", DiscardConfirmed))])
  else Step.with(m, [Ui(Navigate("/customers"))])
```

`UiEffect[Msg]` (in `Ui.Core`) carries `Navigate`, `Back`, `Confirm`,
`Toast`. The runtime renders the dialog and feeds the answer back as a
message. Logic tests assert on the `Confirm` value directly.

### 6.4 Shared state and cross-screen events

- `Ctx` (current user, permissions, locale, feature flags) is passed into
  `init`, `update` and `view`. Screens never copy it into their model.
- Changes to `Ctx` go through effects handled by a pure session reducer.
- Cross-screen events use typed topics: saving emits
  `Publish(CustomerChanged(id))`; the list screen subscribes with
  `subscriptions(m) = [on(CustomerChanged, Refresh)]`. The same `Sub`
  mechanism covers timers and server push.

---

## 7. The `View` type

### 7.1 Shape

```lyric
pub union View[Msg] {
  case Element(kind: WidgetKind, key: String, props: List[Prop], handlers: List[Handler[Msg]], children: List[View[Msg]])
  case Text(value: String)
  case Empty
}
```

`WidgetKind` is a closed enum of semantic widgets:

| Group | Kinds |
|---|---|
| Layout | `Column`, `Row`, `Grid`, `Card`, `Section`, `Spacer` |
| Text | `Heading`, `Paragraph`, `Label`, `Badge` |
| Input | `TextInput`, `TextArea`, `NumberInput`, `Checkbox`, `Select`, `DateInput` |
| Action | `Button`, `Link` |
| Feedback | `Banner`, `Spinner`, `FieldError` |
| Data | `Table`, `TableRow`, `TableCell`, `DataGrid` (future, §13.6) |
| Structure | `Form`, `Field`, `Tabs`, `Tab`, `Dialog` |
| Escape hatch | `Raw` (web hosts only; §7.3) |

Props are typed at the widget-builder level (`button.primary(label, onClick,
busy)`) and carried as name/value pairs in the tree, so the diff and the
protocol stay generic.

### 7.2 Handlers

```lyric
pub union Handler[Msg] {
  case OnClick(msg: Msg)
  case OnInput(toMsg: (String) -> Msg)
  case OnChange(toMsg: (String) -> Msg)
  case OnSubmit(msg: Msg)
}
```

Handlers never cross the wire. The session keeps a handler table keyed by
**stable node path plus event name**; the host sends `(path, event,
payload)` and the session resolves it against the current tree. Because the
key is the path rather than a render counter, an event sent against a
slightly stale render still reaches the right handler; if the node is gone,
the event is dropped and logged.

`Ui.map(view, f)` rewrites every handler of a child view to wrap its message
with `f`, which is how embedded components (§6.2) compose.

### 7.3 `Raw`

`Raw` carries a `SafeHtml` value (constructed only through an escaping
builder). The desktop webview and server web hosts render it; a future
non-HTML host renders an error placeholder and the compiler warns when an
application that declares such a host uses `Raw` (Q-UI-006).

---

## 8. Session loop

One sequential loop per session:

1. Take the next `Msg` from the queue.
2. `update` produces a new model and effects.
3. `view` renders; `Ui.Diff` compares with the previous tree.
4. Patches are sent to the host.
5. Effects are started concurrently; their result messages rejoin the queue.

`update` therefore never needs locking. Effects run under the session's
structured-concurrency `scope`, so closing the session cancels outstanding
effects.

The loop is split into a **pure core** (`Ui.Session.step`: state + msg ->
state + patches + effects) and a thin **driver** that owns the queue and the
transport. The pure core is what hosts and tests share.

---

## 9. Diff and patch protocol

### 9.1 Diffing

- Children are reconciled **by key** when keys are present, positionally
  otherwise. Dynamic lists should key their items; a lint rule is future
  work.
- Same kind and key: props and handlers are compared, children recursed.
- Different kind or key: the node is replaced.

### 9.2 Patch operations

```lyric
pub union Patch {
  case Replace(path: List[Int], node: WireNode)
  case Insert(path: List[Int], index: Int, node: WireNode)
  case Remove(path: List[Int], index: Int)
  case SetProp(path: List[Int], name: String, value: String)
  case RemoveProp(path: List[Int], name: String)
  case SetText(path: List[Int], value: String)
  case SetHandlers(path: List[Int], events: List[String])
}
```

`WireNode` is the handler-free projection of a `View` (events are listed by
name only). Patches within one batch are applied in order; `Remove`
operations for a parent are emitted from the highest index down so that
earlier indices stay valid.

### 9.3 Wire format

JSON in v1 (`Ui.Protocol`), one message per WebSocket frame:

```json
{"t":"patch","v":12,"ops":[{"op":"setText","p":[0,1],"v":"Saving..."}]}
{"t":"event","v":12,"p":[0,3,1],"e":"input","d":"Acme Pty","iv":7}
```

`v` is the render version. A compact binary encoding over `lyric-proto` is
future work (§13.8).

### 9.4 Controlled inputs

The user types "abc"; the server's echo for "ab" arrives afterwards; a naive
host would reset the field and jump the caret. Each input carries an
**input version** (`iv`) that the host increments per local edit and sends
with each event. The session records the last `iv` it processed per input
path and includes it with any `value` prop it sends. The host ignores a
server `value` whose `iv` is older than its latest local edit. Application
code never sees this.

### 9.5 Reconnect

If the session is still alive, the host requests a full render (`{"t":"sync"}`)
and the session replies with a `Replace` of the root. If the session has
expired, the screen re-runs `init` for the current route.

---

## 10. Hosts

### 10.1 Server-driven web (first host)

`Ui.Host.Web` mounts on `lyric-web`: it serves the HTML shell and the
runtime script, and accepts the WebSocket on `/_ui/ws` through `lyric-ws`.
One session per socket.

Costs: each session holds its model and last `View` tree on the server;
line-of-business loads (hundreds of concurrent users) are fine, thousands
need eviction of tree snapshots with re-render on reconnect (Q-UI-007).
Typing is debounced by the host (`input` events coalesce per frame).

### 10.2 Desktop webview (second host)

The same protocol over an in-process channel to a system webview (WebView2,
WKWebView, WebKitGTK) through the C `webview` library. The native backend's
FFI and callback trampolines (N4) cover the binding; MSIL uses the same C
library. JVM desktop is a dated gap (Q-UI-008).

### 10.3 The TypeScript runtime

The browser/webview side is TypeScript. This is the only accepted non-Lyric
component in the UI stack, under these constraints:

- Lives in `lyric-ui/runtime/` and is versioned with the protocol.
- Contains **no application logic**: it applies patches, renders the fixed
  set of semantic widgets, coalesces input events and implements input
  versioning.
- Target size: a few thousand lines, no third-party runtime dependencies.
- Checked in as source with the compiled `ui-runtime.js` produced by a
  pinned `tsc`; CI verifies the compiled file matches the source.

When the client WASM host exists (§13.1) the same widget renderer is reused
and the patch applier becomes a direct call from Lyric.

---

## 11. Forms

### 11.1 Placement

If the form generator emitted code referring to `Ui` types into a domain
package, the domain would depend on the UI, which §5 forbids. So:

- `lyric-forms` (`Forms.*`) is `@pure` and owns `FieldError`, `FieldSpec`,
  `FormSchema` and the scalar parsers. Domain packages may import it.
- The generator is `@generate(Forms.Derive)`, a custom generator (D075)
  emitting only pure code.
- `Ui.Forms` (view layer) renders a `FormSchema` with a draft and errors.

### 11.2 Drafts

A form never edits the domain value. It edits a **draft**: raw text as typed,
which may be invalid. One function maps a draft to a domain value or errors.

```lyric
@generate(Forms.Derive)
pub opaque type Customer @projectable {
  @readonly id: CustomerId
  @label("Name") name: String
  @label("Email") email: Email
  @label("Credit limit") creditLimit: CreditLimit
  @label("Notes") @multiline notes: String?
  invariant: name.length > 0  @message("Name is required")
}
```

Generates (all pure):

```lyric
pub record CustomerDraft { name: String, email: String, creditLimit: String, notes: String }
pub enum CustomerField { Name, Email, CreditLimit, Notes }
pub func customerSchema(): FormSchema
pub func emptyCustomerDraft(): CustomerDraft
pub func toCustomerDraft(c: in Customer): CustomerDraft
pub func setCustomerField(d: in CustomerDraft, f: in CustomerField, v: in String): CustomerDraft
pub func validateCustomer(d: in CustomerDraft, id: in CustomerId): Result[Customer, List[FieldError]]
```

`CustomerField` plus `setCustomerField` collapses per-field messages into a
single `FieldEdited(field, value)` case.

### 11.3 Type to input mapping

| Field type | Draft | Widget | Validation |
|---|---|---|---|
| `String` | `String` | `TextInput` | required unless optional |
| `Int`/`Long range a ..= b` | `String` | `NumberInput` with min/max | parse, then range -> `OutOfRange` |
| `Bool` | `Bool` | `Checkbox` | none |
| `enum` | `String` | `Select` | case-name lookup |
| `T?` | as `T` | as `T` | empty text means `None` |
| `Instant`, date | `String` | `DateInput` | ISO-8601 parse |
| opaque `T` | `String` | `TextInput` | `T.parse(s): Result[T, String]` or `@form_parse(fn)` |
| nested derived record | nested draft | `Section` | recursive, dotted field paths |
| `List[T]` | `List[TDraft]` | repeater | future (Q-UI-009) |

### 11.4 Invariants become messages

The generator copies each `invariant:` expression into `validate` as a
boolean check evaluated **before** construction, mapping a failure to
`FieldError.CrossField(message)`. Construction then cannot fail at runtime.
In `@proof_required` domains, `validate` returning `Ok` implies the invariant
holds, which the verifier can discharge. This requires the generator API to
expose invariant expressions to generators (Q-UI-004).

### 11.5 Client-side and asynchronous validation

Bounds and `required` flags travel to the host as props for instant
feedback; server-side `validate` is authoritative. Asynchronous rules
("email already in use") are effects whose results merge into `errors`.

### 11.6 Until the generator ships

Phase U1 ships `lyric-forms` as a hand-usable library: the example writes
the draft, field enum, schema and `validate` by hand using `Forms.Parse`
helpers. That code is exactly what the generator will emit, so it also
serves as the generator's golden output (§14).

---

## 12. Testing

### 12.1 Logic

```lyric
test "invalid credit limit blocks save and emits no effect" {
  val s0 = init(testId)
  val s1 = update(s0.model, Loaded(Ok(sample)))
  val s2 = update(s1.model, FieldEdited(CreditLimit, "2000000"))
  val s3 = update(s2.model, SaveClicked)
  assertTrue(s3.effects.isEmpty, "no save effect")
  assertTrue(hasError(s3.model.errors, "creditLimit"), "range error reported")
}
```

### 12.2 Views

Views are values, so `Ui.Testing` offers queries over a `View` tree
(`findByLabel`, `textOf`, `click(view, label)` returning the `Msg` a click
would produce). No rendering is involved.

### 12.3 Replay

A session driver can record every incoming `Msg`. Because `update` is
deterministic (§4.5), feeding the recording to a fresh session reproduces
the exact model and view.

---

## 13. Future state

### 13.1 Client-side WASM host

The native (LLVM) backend compiled to `wasm32`, with `lyric-rt` built by
`wasi-sdk`. ARC means no garbage collector is shipped to the browser. The
session loop runs in the browser and applies patches through a thin import
into the TS runtime. Chosen over the .NET browser-wasm runtime because of
size (several MB for .NET). Depends on `docs/35`.

### 13.2 `@generate(Embed)`

Generates the delegation boilerplate of §6.2 (the wrapping `Msg`/`Effect`
cases, the `update` delegation and the outcome fold skeleton) from a
declaration such as `@embed(picker: Picker)`. Deferred until the explicit
pattern has been used in real applications.

### 13.3 Non-HTML hosts

A Skia-based renderer or native widget hosts behind the same `WidgetKind`
vocabulary. The semantic vocabulary is what keeps this possible. Cost: text
shaping, IME and accessibility become the library's problem.

### 13.4 Server-side rendering for first paint

The web host renders the initial `View` to HTML in the shell so the first
paint does not wait for the WebSocket.

### 13.5 `Lazy` subtrees

`Lazy(key, deps, render)` skips rendering and diffing a subtree when a
structural hash of `deps` is unchanged. Needs `derives Hash` (or
equivalent) on model types.

### 13.6 Data grid

A host widget with its own sub-protocol: the host reports the visible row
window; the grid issues `FetchRows(range, sort, filter)` effects; results are
patched in. This is the single largest component for line-of-business use.

### 13.7 Offline and optimistic updates

Not planned for the server-driven host. The WASM host makes offline use
possible.

### 13.8 Binary protocol

`lyric-proto` encoding of patches and events once the JSON protocol is
stable.

### 13.9 Accessibility and theming

Each semantic widget maps to ARIA roles once, in the runtime. Theming via CSS
custom properties (design tokens) with light and dark sets.

---

## 14. Phases

| Phase | Scope | Status |
|---|---|---|
| U1 | `lyric-forms`; `lyric-ui` pure core (`Ui.Core`, `Ui.Widgets`, `Ui.Diff`, `Ui.Protocol`, `Ui.Session`, `Ui.Testing`); example logic, view and tests | Implemented (MSIL) |
| U2 | Server-driven web host (`Ui.Host`) + TS runtime; example runs in a browser | Implemented (MSIL); host and runtime covered by `lyric test` and `node --test`, no browser end-to-end test yet |
| U3 | `[layers]` compiler feature, stdlib `@pure`/`@io` classification, `Y000x` diagnostics | Planned |
| U4 | `@generate(Forms.Derive)` and `@generate(Ui.Routes)` | Planned |
| U5 | Desktop webview host (native + MSIL) | Planned |
| U6 | Data grid, `Lazy`, SSR first paint | Planned |
| U7 | Client WASM host | Depends on `docs/35` |

---

## 15. Findings from the first implementation

Implementing Phase U1/U2 and `examples/ui-customers/` against the
self-hosted compiler of 2026-09-24 surfaced the following. The typed
`View[Msg]` combinator API is exactly the shape the monomorphizer and MSIL
codegen handled least well, so the compiler findings were fixed in the
compiler rather than worked around in the library: F-1 to F-8 in #7215
(D-progress-944 and 946 to 954), and the gaps the example then hit (another
package's function as a value, range-type stringification, generic
inference) in #7250 (D-progress-963 to 969). A record `.copy` with a bare
`None` argument built an untyped `Option` on MSIL; that is fixed alongside
this library (D-progress-970). With those, `lyric-forms` (7 tests),
`lyric-ui` (40) and `examples/ui-customers` (14) pass on MSIL, and the
example uses `.copy` and inferred type arguments rather than helpers.

### Compiler: generics (resolved)

- **F-1: record `.copy(...)` is specified but not implemented.** docs/01
  §2.4 documents `p.copy(x = 3.0)`; the type checker reports T0113 "no method
  'copy'". Model-view-update updates are almost all non-destructive record
  updates, so every transition spells out the full constructor. Workaround
  in the example: a per-screen `next(...)` helper.
- **F-2: generic type-argument inference is argument-only and shallow.** The
  monomorphizer infers from literals, parameters and annotated locals. It
  does not use the expected type (a binding annotation, a `return`, or a
  parameter), so a function whose type parameter appears only in its return
  type (`stay[M, E](m)`, `heading[Msg](1, "Title")`, `nothing[Msg]()`)
  cannot be called without explicit type application. It also does not type
  union-case values (`button("Save", SaveClicked)`), match-bound variables,
  generic-record field reads (`split.effects`) or most generic call results.
  Record constructors ignore the expected type (T0110) although union
  constructors use it. Explicit type application works only on unqualified
  names at concrete call sites; `f[T](...)` naming an enclosing function's
  type parameter is rejected by the type checker (T0020).
- **F-3: qualified explicit type application fails at codegen.**
  `Widgets.button[Msg]("Save", Go)` type-checks and then fails with T0115;
  `import Ui.Widgets.{button}` plus `button[Msg](...)` works.
- **F-4: specialising an imported generic copies its body into the
  consumer.** Private helpers called from a `pub` generic are unresolvable
  in the consumer (T0123), so every helper becomes public API, and generic
  calls nested inside a specialised body are sometimes left unresolved.
- **F-5: calling a function value inside a lambda breaks after
  specialisation.** In a generic specialised into another package,
  `{ s -> f(g(s)) }` resolves `f` as a named function (T0123), even when `f`
  is first bound to a typed local. This makes `mapView` (embedding a child
  component) uncompilable.
- **F-6: member access on an imported generic record returned by a call
  erases to `object`** (T0121) unless the result is first bound to an
  annotated local.
- **F-7: diagnostics from a specialised imported body report the consumer's
  file path with the library's line numbers**, which makes the errors above
  hard to locate.

### Compiler: other

- **F-8: qualified names resolve across packages by simple name.** In a
  project bundle `Widgets.field(...)` resolved to `Forms.field(...)`, and
  with `import Std.Testing` plus `import Ui.Testing`, `Testing.click`
  silently resolved to `Std.Testing` (T0020) instead of reporting an
  ambiguity. Worked around by renaming (`Forms.fieldSpec`) and aliasing
  (`import Ui.Testing as UiTest`).
- **F-9: reserved words.** `out`, `old`, `result`, `when`, `record` and
  `end` are keywords; names a UI library naturally reaches for. Not a bug,
  but worth a naming note in the style guide.
- **F-10: no generic protected types** (on any backend), so a session is
  held in a single-owner one-slot `List` cell rather than a protected cell.

### Libraries and targets

- **F-11: `lyric-ws` runs its own listener** and `lyric-web` has no upgrade
  hook, so the web host serves HTTP on `port` and the session WebSocket on
  `wsPort`. The shell derives the socket URL from the `Host` header.
- **F-12: the only cross-target JSON value model is `JsonRpc.Json`**
  (`Std.Json` is a read-only, .NET-only cursor). `Ui.Protocol` depends on
  `lyric-jsonrpc` for it; a writer-capable `Std.Json` value model belongs in
  the stdlib.
- **F-13: native cannot consume `lyric-ui` yet.** Native project builds do
  not resolve `[dependencies]` (#6815 item 1(b)), so a native application
  cannot depend on `lyric-ui` or `lyric-forms`, which blocks the priority
  target. Generic protected types are also unsupported on native.
- **F-14: `@generate` custom generators are not usable end to end.** The
  compiler side exists, but a generator DLL must be staged by hand under
  `.lyric/packages/`, and nothing in CI runs a real generator. Phase U4
  depends on fixing this.
- **F-15: effects run one at a time per session.** `Ui.Host` runs each
  step's effects sequentially on the connection's thread (the busy state is
  sent first). Concurrent effects need a per-session queue with a lock or
  actor, which wants a generic protected type (F-10).

### Consequence for the plan

The compiler work came first (Q-UI-011 is resolved in favour of fixing the
compiler, not reshaping the library). F-9 is a naming note. F-10 to F-15
remain open and bound later phases: F-13 blocks the native host (U5 on
native), F-14 blocks U4, and F-10/F-15 are needed before effects run
concurrently.

---

## 16. Open questions

- **Q-UI-001** Should `Step` be a record or a tuple? Tuples read better in
  `update`, records are clearer in tests and extend without breaking callers.
- **Q-UI-002** Should `Ctx` be a generic parameter of `Screen` (application
  defined) or a fixed library record with an extension slot?
- **Q-UI-003** How is module-level mutable state and `protected type` access
  detected in pure layers (§5.5)?
- **Q-UI-004** Does the D075 generator API expose `invariant:` expressions
  and field annotations to generators, or does it need extending?
- **Q-UI-005** Should the handler table key include the widget key when
  present (more robust to reordering) rather than the path alone?
- **Q-UI-006** How does an application declare its hosts, so that `Raw`
  use can be diagnosed at compile time?
- **Q-UI-007** Session memory policy for the server host: cap, eviction of
  tree snapshots, or both?
- **Q-UI-008** JVM desktop host: JavaFX `WebView`, or a JNI binding of the
  same C `webview` library?
- **Q-UI-009** Representation of `List[T]` fields in drafts and error paths.
- **Q-UI-010** Should the TS runtime be generated from a Lyric description
  of the widget set (single source of truth for props), or hand-written?
- **Q-UI-011** *Resolved:* the cross-package generics gaps (§15 F-2 to F-7)
  were fixed in the compiler (#7215, #7250) and `lyric-ui` keeps its typed
  `View[Msg]` API.
