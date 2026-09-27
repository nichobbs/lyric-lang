# Chapter 31: User Interfaces

Line-of-business applications spend most of their code on screens: a form
that loads a record, lets someone edit it, validates it, saves it and moves
on. `lyric-ui` and `lyric-forms` give those screens one application model
that is the same whether the screen is served to a browser or, later,
shown in a desktop window. This chapter builds the edit-customer screen
from `examples/ui-customers/`, then tests it and serves it.

The libraries are `@experimental`. The pure core, the forms helpers and
the server-driven web host are implemented; the desktop and WebAssembly
hosts, the `[layers]` checker and the form generator are designed but not
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
| `Notify(message, level)` | shows a toast (`Info`, `Success`, `Warning`, `Error`) |

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
| Data | `table`, `tableRow` |

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
"not found". Run the example and open the printed address:

```sh
lyric run --manifest examples/ui-customers/lyric.toml
# Customers: http://localhost:8080/customers/1
```

### Host configuration

`WebHost.defaultConfig(title)` returns a `HostConfig` with these fields;
change any of them with `.copy`:

| Field | Default | Meaning |
|---|---|---|
| `port` | 8080 | HTTP port for the page and assets |
| `wsPort` | 8081 | WebSocket port for sessions |
| `wsPath` | `/_ui` | WebSocket path |
| `publicWsUrl` | `""` | socket URL for browsers, when a proxy routes it elsewhere |
| `reconnectGraceMs` | 120000 | how long a disconnected session can be resumed |
| `maxSessions` | 10000 | sessions held in memory |

### Sessions and reconnection

Every page load gets a session with an unguessable 128-bit id. If the
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
A later release enforces these rules with a `[layers]` table in
`lyric.toml` (`docs/65` §5).

## Platform support

The library, the forms helpers and the example build and pass their tests
on both `--target dotnet` and `--target jvm`. The web host serves browsers
from either runtime.
