# Chapter 31: User Interfaces

Line-of-business applications spend most of their code on screens: a form
that loads a record, lets someone edit it, validates it, saves it and moves
on. `lyric-ui` and `lyric-forms` give those screens one application model
that is the same whether the screen is served to a browser or, later,
shown in a desktop window. This chapter builds the edit-customer screen
from `examples/ui-customers/`, then tests it and serves it.

The libraries are `@experimental`. The pure core, the forms helpers, the
server-driven web host and the `[layers]` checker are implemented; the
desktop and WebAssembly hosts and the form generator are designed but not
built yet (`docs/65-ui-library-sketch.md` §14).

## Adding the dependencies

```toml
# lyric.toml
[dependencies]
"Lyric.Forms" = { path = "../lyric-forms" }
"Lyric.Ui" = { path = "../lyric-ui" }
```

## The model-view-update loop

A screen is four things:

- a **model**, the screen's whole state, as an ordinary record;
- **messages**, a union of everything that can happen to it;
- a pure **`update`** that turns a model and a message into a new model
  plus the effects it wants run;
- a pure **`view`** that turns a model into a description of what to show.

```lyric
pub func init(id: in CustomerId): Step[Model, Effect]
pub func update(m: in Model, msg: in Msg): Step[Model, Effect]
pub func view(m: in Model): View[Msg]
pub async func run(e: in Effect, repo: in CustomerRepository): Option[Msg]
```

The fourth function, `run`, is the only one that performs I/O. The
runtime calls `update` for each message, runs the effects it returned, and
feeds the messages those effects produce back into `update`.

`Step` is a record, built with three helpers:

```lyric
stay(m)            // new model, no effects
step1(m, e)        // one effect
stepAll(m, es)     // several effects
```

Effects are **data**. `update` never calls a repository: it returns
`SaveCustomer(customer = c)`, and a test can assert that it did.

## Model, messages and effects

The edit screen's state and events:

```lyric
pub union Status {
  case Loading
  case Editing
  case Saving
  case LoadFailed(message: String)
}

pub record Model {
  id: CustomerId
  draft: CustomerDraft
  errors: List[FieldError]
  status: Status
  dirty: Bool
  saveError: Option[String]
}

pub union Msg {
  case Loaded(outcome: Result[Customer, String])
  case FieldEdited(field: CustomerField, value: String)
  case SaveClicked
  case Saved(outcome: Result[Customer, String])
  case CancelClicked
  case DiscardConfirmed
  case RetryClicked
}

pub union Effect {
  case LoadCustomer(id: CustomerId)
  case SaveCustomer(customer: Customer)
  case Ui(effect: UiEffect[Msg])
}
```

Two kinds of effect appear here. `LoadCustomer` and `SaveCustomer` belong
to the application and are run by `run`. `UiEffect` belongs to the
runtime, which interprets it itself:

| `UiEffect` case | What the runtime does |
|---|---|
| `Navigate(url)` | moves to another screen |
| `Back` | returns to the previous screen |
| `Confirm(question, onYes)` | shows a yes/no dialog; `onYes` is dispatched on yes |
| `Notify(message, level)` | shows a toast (`Info`, `Success`, `Warning`, `Error`); a toast shown with a navigation stays up on the next page |

A screen wraps them in one case of its own `Effect` (here `Ui`) and tells
the runtime how to find them:

```lyric
pub func uiEffect(e: in Effect): Option[UiEffect[Msg]] {
  return match e { case Ui(u) -> Some(value = u); case _ -> None }
}
```

## Update

`update` is an ordinary `match`. Record `.copy` keeps each transition
short:

```lyric
pub func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case Loaded(Ok(c)) -> stay(m.copy(draft = toCustomerDraft(c), status = Status.Editing))
    case Loaded(Err(e)) -> stay(m.copy(status = LoadFailed(message = e)))
    case RetryClicked -> step1(m.copy(status = Status.Loading), LoadCustomer(id = m.id))
    case FieldEdited(f, v) -> onEdit(m, f, v)
    case SaveClicked -> onSave(m)
    case Saved(Ok(c)) -> {
      val es: List[Effect] = newList()
      es.add(Ui(effect = Notify(message = "Customer saved", level = ToastLevel.Success)))
      es.add(Ui(effect = Navigate(url = listUrl)))
      stepAll(m.copy(draft = toCustomerDraft(c), status = Status.Editing, dirty = false), es)
    }
    case Saved(Err(e)) -> stay(m.copy(status = Status.Editing, saveError = Some(value = e)))
    case CancelClicked ->
      if m.dirty then step1(m, Ui(effect = Confirm(question = "Discard your changes?", onYes = DiscardConfirmed)))
      else step1(m, Ui(effect = Navigate(url = listUrl)))
    case DiscardConfirmed -> step1(m.copy(dirty = false), Ui(effect = Navigate(url = listUrl)))
  }
}
```

The confirmation dialog shows the pattern for asking the user something:
the screen returns `Confirm` with the message to send on yes, and handles
that message like any other. There is no callback and no hidden state.

Because `update` is deterministic, anything it needs must arrive in the
message. A timestamp, a generated id or the result of a lookup is fetched
by an effect and delivered as a message, never read inside `update`.

## Running effects

`run` maps each application effect to the message that reports its
outcome:

```lyric
pub async func run(e: in Effect, repo: in CustomerRepository): Option[Msg] {
  return match e {
    case LoadCustomer(id) -> Some(value = Loaded(outcome = await repo.find(id)))
    case SaveCustomer(c) -> Some(value = Saved(outcome = await repo.save(c)))
    case Ui(_) -> None
  }
}
```

`CustomerRepository` is an interface (a port). The application binds an
implementation at its composition root, so tests and the demo can use an
in-memory store.

The host runs the effects of a step concurrently, each on its own task,
and applies their messages one at a time in the order they finish. A slow
effect therefore holds up neither the others nor the user's input. `update`
never runs concurrently with itself, so it needs no locking. When a session
ends, effects still running are cancelled and their results are dropped.

## View

`view` builds a `View[Msg]`: a tree of semantic widgets, not HTML. Each
widget that can be interacted with carries the message it produces.

```lyric
pub func view(m: in Model): View[Msg] {
  return match m.status {
    case Loading -> Widgets.spinner("Loading customer")
    case LoadFailed(message) -> {
      val cs: List[View[Msg]] = newList()
      cs.add(Widgets.banner("error", "Could not load the customer: " + message))
      cs.add(Widgets.button("Retry", RetryClicked))
      Widgets.column(cs)
    }
    case _ -> editor(m)
  }
}
```

The widget set is closed and describes intent, so every host can render
it natively:

| Group | Widgets |
|---|---|
| Layout | `column`, `row`, `card`, `section` |
| Text | `heading`, `paragraph`, `badge`, `showIf` |
| Feedback | `banner`, `spinner` |
| Actions | `button`, `primaryButton`, `buttonWith`, `link` |
| Forms | `form`, `field`, `textInput`, `textArea`, `numberInput`, `checkbox`, `select` |
| Data | `table`, `tableRow`, `dataGrid`, `gridRow` |

Input widgets take a function from the typed text to a message, for
example `Widgets.textInput("text", m.name, { v: String -> NameEdited(value = v) }, Widgets.inputOpts())`.

### Keys for dynamic lists

Wrap each item of a list that can change with `keyed`:

```lyric
for c in m.customers {
  rows.add(Widgets.keyed(c.id.toString(), customerRow(c)))
}
```

Keys let the runtime move a row rather than rebuild it when the list is
reordered. They also make events safe: an event names the node it came
from by key, so a click on a row that moved before the click arrived still
reaches that row, and a click on a row that has since gone is dropped
rather than delivered to its neighbour.

### Skipping unchanged subtrees

Every update renders the whole view and compares it with the last one.
For a large subtree that rarely changes, wrap it in `lazyView` with a
fingerprint of what it reads:

```lyric
Widgets.lazyView("orders", m.ordersVersion.toString(), { -> ordersTable(m.orders) })
```

The session renders the subtree once per fingerprint. While the
fingerprint is unchanged it keeps the subtree it rendered last and does
not compare it, so updates elsewhere on the screen do not render or diff it
(the session still walks it once per update).
The fingerprint must change whenever anything the subtree shows changes:
a version counter bumped by `update`, or an id plus an edit count. A
stale fingerprint shows stale content. Each `lazyView` key must be unique
within the view.

Events, keys and `Ui.Testing` see through a lazy subtree, so tests and
handlers work as they do without it.

### Large lists: the data grid

A `table` renders every row it is given. For a result too large to hold,
use `dataGrid`: it renders a window of rows inside a scrolling body sized
for all of them, and asks the screen for more as the user scrolls. The
customer list in the example is one:

```lyric
val spec = Widgets.gridSpec("Customers", columns(), g.total, g.first).copy(
  sortColumn = g.sortColumn,
  ascending = g.ascending
)
page.add(Widgets.dataGrid(spec, rows, { r: RowRange -> Scrolled(range = r) }, { c: String -> Sorted(column = c) }))
```

The grid's state lives in the model as a `Ui.Grid.Grid[Customer]`, and
`Ui.Grid` turns its events into queries:

```lyric
case Scrolled(r) -> withQuery(m.status, Grid.viewport(m.grid, r))
case Sorted(column) -> withQuery(m.status, Grid.sortBy(m.grid, column))
```

Each step carries an optional `RowQuery` (rows, sort, filter and a
sequence number). `withQuery` returns it as the screen's own
`FetchRows` effect, and the effect's result comes back as a message that
`Grid.loaded` applies. Scrolling within the loaded rows asks for nothing.
A response to anything but the latest query is ignored, so a slow page
never replaces a newer one.

Rows are `gridRow`s keyed by the record's id, one cell per column. The
grid is a WAI-ARIA grid: the arrow keys move between rows, and a row with
an `onClick` message is activated with Enter or Space.

### Typed routes

Pages are a union, so a link names a page rather than a URL.
`Ui.Routes` derives the URL functions from `@path` annotations:

```toml
"Ui.Routes" = { path = "../lyric-ui/routes" }
```

```lyric
@generate(Ui.Routes)
pub union Route {
  @path("/customers") case CustomerList
  @path("/customers/{id:Long}") case EditCustomer(id: CustomerId)
}
```

This generates `parseRoute(url): Option[Route]` and `routeUrl(r): String`:

- **Placeholders:** each `{field}` segment binds a case field.
- **Types from another file:** `{id:Long}` reads the segment as a `Long`
  and converts it with `CustomerId.tryFrom`, so `/customers/0` matches no
  route when `CustomerId` starts at 1. A field whose type is declared in
  the same file needs no `:Long`.
- **Matching:** cases are tried in declaration order, and the query and
  fragment are ignored.

A view links with `Widgets.link(c.name, routeUrl(EditCustomer(id = c.id)))`.
The application maps each route to a screen with an exhaustive `match`, so
adding a page without a screen does not compile:

```lyric
func screenFor(repo: in CustomerRepository, r: in Route): Instance {
  return match r {
    case CustomerList -> listScreen(repo)
    case EditCustomer(id) -> editScreen(repo, id)
  }
}
```

The `ui` layer preset lets logic, effects and views import `Ui.Routing`,
the pure package the generated code uses.

### Composing screens

A child component has its own message type. `mapView` lifts its view into
the parent's:

```lyric
val child: View[ChildMsg] = Picker.view(m.picker)
val lifted: View[Msg] = mapView(child, { c: ChildMsg -> FromPicker(msg = c) })
```

## Forms

`lyric-forms` is independent of any UI. It describes fields, parses the
raw text a user typed into domain values, and reports every problem at
once.

A **schema** lists the fields:

```lyric
pub func customerSchema(): FormSchema {
  val fs: List[FieldSpec] = newList()
  fs.add(Forms.maxLength(Forms.required(Forms.fieldSpec("name", "Name", InputKind.Text)), 100))
  fs.add(Forms.required(Forms.fieldSpec("email", "Email", InputKind.Email)))
  fs.add(Forms.bounded(Forms.required(Forms.fieldSpec("creditLimit", "Credit limit", InputKind.Number)), 0, 1_000_000))
  return Forms.schema(fs)
}
```

A **draft** holds the text as typed, so a half-typed number is not an
error until the user tries to save. Validation parses each field with the
`Forms.Parse` helpers, collecting errors rather than stopping at the
first:

```lyric
pub func validateCustomer(d: in CustomerDraft, id: in CustomerId): Result[Customer, List[FieldError]] {
  val errs: List[FieldError] = newList()
  val name = Parse.collect(errs, Parse.requiredText(fieldPath("name"), d.name), "")
  val email = Parse.collect(errs, Parse.email(fieldPath("email"), d.email), "")
  val limit = Parse.collect(errs, Parse.longInRange(fieldPath("creditLimit"), d.creditLimit, 0, 1_000_000), 0)
  if errs.count > 0 {
    return Err(error = errs)
  }
  ...
}
```

`FieldError` is a union: `Required`, `Invalid`, `OutOfRange`, `TooLong`,
and `CrossField` for a rule that spans fields (such as "key accounts need
a credit limit of at least 10000"). Each field error carries a
`FieldPath`, and `Forms.errorsFor`, `Forms.hasErrorFor` and
`Forms.formErrors` select errors for a field or the form.

`Ui.Forms.formFields` renders a schema as labelled inputs with their
errors underneath:

```lyric
val fields = Ui.Forms.formFields(
  customerSchema(),
  { name: String -> valueOf(draft, name) },
  m.errors,
  { name: String, value: String -> edited(name, value) }
)
```

### Deriving a form

The schema, draft and validation above follow mechanically from the domain
type, so `Forms.Derive` writes them. It is a source generator (chapter 30):
declare it next to `Lyric.Forms` and annotate the type:

```toml
[dependencies]
"Lyric.Forms"  = { path = "../lyric-forms" }
"Forms.Derive" = { path = "../lyric-forms/derive" }
```

```lyric
pub type CreditLimit = Long range 0 ..= 1_000_000

pub enum Tier {
  case Standard
  case Preferred
  @label("Key account") case Key
}

@generate(Forms.Derive)
pub record Customer {
  @readonly id: CustomerId
  @maxLength(100) name: String
  @email email: String
  creditLimit: CreditLimit
  tier: Tier
  @multiline @maxLength(2000) notes: Option[String]
  invariant: keyAccountLimitOk(tier, creditLimit) @message("Key accounts need a credit limit of at least 10000")
}
```

This generates:

- `CustomerDraft` and the `CustomerField` enum;
- `customerSchema()`, which labels each field (by default `creditLimit`
  becomes "Credit limit");
- `emptyCustomerDraft()`, `toCustomerDraft(c)`, `customerDraftValue(d, f)`,
  `setCustomerField(d, f, text)` and `customerFieldNamed(name)`;
- `validateCustomer(d, id)`.

How fields map to inputs:

- **Range type:** a number input with its bounds.
- **Enum:** a select of its cases.
- **`Option`:** an optional field, where empty text means `None`.
- **`@readonly`:** the field is left out of the form and passed to
  `validateCustomer` instead.

`validateCustomer` parses every field and reports every error at once. It
then checks each invariant and turns a failure into a `CrossField` error
carrying its `@message`, and only then builds the `Customer`, so
construction cannot fail.

A field type the generator cannot edit is an `FD002` error. For such a type
(a date, or a type declared in another file), supply the two functions it
needs:

```lyric
@form_parse(parseDate) @form_format(formatDate) due: Date
```

Here `parseDate(text): Result[Date, String]` reports its `Err` text under
the field, and `formatDate(d): String` fills the draft.

### Lists of rows

A form that edits a list (the lines of an order) keeps its rows in
`DraftRows[D]`, which gives every row a stable id:

```lyric
var lines: DraftRows[LineDraft] = Forms.emptyRows()
lines = Forms.addRow(lines, emptyLine())
lines = Forms.updateRow(lines, id, { d: LineDraft -> d.copy(qty = text) })
lines = Forms.moveRow(lines, id, 0)
```

Errors for a row use a path such as
`Forms.child(Forms.item(Forms.fieldPath("lines"), row.id), "qty")`, so they
stay attached to the right row when rows are added, removed or reordered.
`Forms.validateRows` validates every row and reports each error at its
row's path.

## Testing a screen

Nothing in a screen needs a browser to test. `update` is a function, so
logic tests call it and look at the model and effects:

```lyric
test "an out-of-range credit limit blocks save and reports the field" {
  val m = edit(loaded(), CustomerField.CreditLimitField, "2000000")
  val s = Logic.update(m, SaveClicked)
  assertEqualInt(s.effects.count, 0, "no save effect")
  assertTrue(Forms.hasErrorFor(s.model.errors, Forms.fieldPath("creditLimit")), "credit limit error")
}
```

`Ui.Testing` queries a `View` the way a user would see it:

| Function | Returns |
|---|---|
| `hasText(v, s)` | whether `s` appears anywhere |
| `click(v, label)` | the message the button labelled `label` sends |
| `typeInto(v, label, text)` | the message typing into the field labelled `label` sends |
| `fieldErrors(v, label)` | the error messages shown under that field |
| `findButton(v, label)` | the button itself |

```lyric
test "the error is shown under its field" {
  val s = Logic.update(edit(loaded(), CustomerField.CreditLimitField, "2000000"), SaveClicked)
  val shown = UiTest.fieldErrors(View.view(s.model), "Credit limit")
  assertEqual(shown[0], "Credit limit must be between 0 and 1000000", "message")
}
```

A test can also drive the whole screen through `Ui.Session`, sending
host-shaped events and checking the patches and navigation that come
back. The example's `tests/edit_tests.l` does all three.

## Serving the screen

`Ui.Host.Web` serves screens to a browser. The server keeps each
session's model and renders on the server; the browser runs a small
TypeScript runtime that applies patches and reports events over a
WebSocket.

A `Program` bundles a screen's functions, and `instance` binds it to its
effect runner:

```lyric
func editScreen(repo: in CustomerRepository, id: in CustomerId): Instance {
  val p = Program(update = Logic.update, view = View.view, uiEffect = Logic.uiEffect)
  return instance(p, Logic.init(id), { e: Logic.Effect -> Effects.run(e, repo) })
}

func main(): Unit {
  val repo = Store.seeded()
  match WebHost.serve(WebHost.defaultConfig("Customers"), { url: String -> route(repo, url) }) {
    case Ok(_) -> ()
    case Err(e) -> Console.error("Customers: could not start: " + e)
  }
}
```

`route` maps the URL a browser opened to a screen instance, or `None` for
"not found". The example serves two screens: the customer list at
`/customers` and the editor at `/customers/{id}`, which returns to the
list after a save or a cancel. Run it and open the printed address:

```sh
lyric run --manifest examples/ui-customers/lyric.toml
# Customers: http://localhost:8080/customers
```

`scripts/ci/ui-browser-e2e.sh` drives the same example in headless
Chromium with Playwright: it edits, saves, checks the toast on the list
page, and drops the socket to check that the session resumes.

An async effect runner is called directly: `Effects.run(e, repo)` is an
`async func`, and a direct call to one waits for its result wherever it
appears, including a lambda body like this one.

### Host configuration

`WebHost.defaultConfig(title)` returns a `HostConfig` with these fields;
change any of them with `.copy`:

| Field | Default | Meaning |
|---|---|---|
| `port` | 8080 | port for the page, its assets and the session WebSocket |
| `wsPath` | `/_ui` | session WebSocket path |
| `publicWsUrl` | `""` | socket URL for browsers, when a proxy routes it elsewhere |
| `reconnectGraceMs` | 120000 | how long a disconnected session can be resumed |
| `maxSessions` | 10000 | sessions held in memory |
| `prerender` | `true` | render each page's first view into the HTML |

### First paint

With `prerender` on, the page does not wait for the WebSocket to show
something. The host starts the session as it serves the page. It renders
that session's first view into the HTML and puts the session's id in the
page; the runtime resumes that session when its socket connects. So
`init` and its effects run once, and the live view replaces the
prerendered markup without a visible change.

Until the socket connects, the page is inert: it has no event handlers,
and the mount point carries `aria-busy="true"`. The runtime clears it once
the live view is applied, so a test waits for `#lyric-ui:not([aria-busy])`.

Each prerendered page names a session, so the host serves it with
`Cache-Control: no-store`. A session that no browser claims expires after
`reconnectGraceMs`, like a disconnected one. When `maxSessions` is reached,
unclaimed sessions are evicted first, so page loads that never connect
(crawlers, `curl`) do not push out a user who is reconnecting. The first view is whatever
`init` and the view produce before its effects finish, typically a
loading state.

### Sessions and reconnection

Every page load gets a session with an unguessable 128-bit id (with
`prerender` on, it is created as the page is served). If the
connection drops (a laptop sleeps, a network changes), the browser
reconnects with that id and continues where it left off, as long as it
returns within `reconnectGraceMs`. A disconnected session keeps only its
model; the view is rebuilt from it on resume. When `maxSessions` is
reached, the longest-disconnected sessions are evicted first; if every
session is connected, a new visitor sees a "server busy" page.

The session id is a bearer credential: whoever holds it can take over
the session during the grace period. Serve production traffic over TLS.
The host speaks plain HTTP and `ws`, so put a TLS-terminating proxy in
front of it. When the proxy sends `X-Forwarded-Proto: https`, the page
opens a `wss` socket; if the proxy exposes the socket at another address,
set `publicWsUrl`:

```lyric
val cfg = WebHost.defaultConfig("Customers").copy(publicWsUrl = "wss://app.example.com/_ui")
```

## Structuring a screen

The example splits one screen across five packages, one per layer:

| Package | Layer | May import |
|---|---|---|
| `Customers.Domain` | domain | `Std.*`, `Forms` |
| `Customers.Ports` | ports | domain |
| `Customers.Edit.Logic` | logic | domain, `Ui.Core` data types |
| `Customers.Edit.Effects` | effects | logic, ports |
| `Customers.Edit.View` | view | logic, domain, `Ui.Widgets`, `Ui.Forms` |

Only the composition root (`Customers`) sees every layer. Keeping I/O in
the effects layer is what makes the logic and view testable without mocks.

The compiler enforces the split. The example's `lyric.toml` names the `ui`
preset and places each package:

```toml
[layers]
preset = "ui"

[layers.packages]
"Customers.Domain"    = "domain"
"Customers.Ports"     = "ports"
"Customers.*.Logic"   = "logic"
"Customers.*.Effects" = "effects"
"Customers.*.View"    = "view"
```

A logic package that imports `Std.File`, or a view that imports the ports,
now fails the build:

```
src/edit_logic.l: error[Y0001] 11:1: package Customers.Edit.Logic in layer 'logic' may not import Std.File (@io)
src/list_view.l: error[Y0001] 9:1: package Customers.List.View in layer 'view' may not import Customers.Ports (layer 'ports')
```

Imports are judged by the imported package's layer, or by its class:
every stdlib and library package is marked `@pure` or `@io` on its
`package` line. Logic and view layers may not do I/O at all, so calling
`Time.now()` (an `@io` function in the otherwise pure `Std.Time`) from
`update` is also an error (`Y0003`), as is keeping a `List` or a protected
object in a module-level `val` (`Y0007`); the current time reaches logic
as a message instead. The store adapter and the entry point stay outside
any layer, where every layer meets. The full rules and diagnostics are in
the language reference §9.4.

## Platform support

The library, the forms helpers and the example build and pass their tests
on both `--target dotnet` and `--target jvm`. The web host serves browsers
from either runtime.
