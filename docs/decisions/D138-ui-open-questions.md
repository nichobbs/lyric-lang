# D138 — UI library: resolutions of Q-UI-001 to Q-UI-010

**Status:** accepted. Q-UI-001, Q-UI-005, Q-UI-007 and Q-UI-009 are
implemented (D-progress-979); the others are designs recorded ahead of the
phase that needs them.

**Sketch:** `docs/65-ui-library-sketch.md` (extends D137). Each resolution
below replaces the corresponding open question in §16 and is reflected in
the section named in parentheses.

## Implemented

### Q-UI-001 — `Step` is a record (§4.1)

`Step[M, E]` stays the record `{ model: M, effects: List[E] }`. Named fields
read better in test assertions, work with `.copy`, and can gain a field
without breaking callers; the construction helpers (`stay`, `step1`,
`stepAll`) remove the verbosity a tuple would have saved.

### Q-UI-005 — Events address nodes by key where one exists (§7.2, §9.3)

A path addressed purely by child index misroutes an event when the tree
changes between render and click: a click on row 3's "Delete" while a patch
removing row 1 is in flight would resolve to what was row 4. Event paths
therefore name each step by the node's **key** when it has one and by its
index otherwise. On the wire a segment is a JSON string (key) or number
(index): `"p":[0,"cust-42",1]`. The session resolves a key segment only
when exactly one sibling carries that key; an unknown or duplicated key, or
an out-of-range index, drops the event (logged, never misrouted).

Input versions (§9.4) are recorded against the same stable form of the path,
so an input keeps its version history across reorders. Patch paths stay
index-only: patches are applied in order to a tree that matches the
session's, so indices are exact there.

This changes the event format, so `protocolVersion` becomes 2. Unkeyed
dynamic lists still resolve positionally; the lint rule for them (§9.1)
remains future work and becomes more valuable.

### Q-UI-007 — Session memory policy and reconnect (§8, §9.5, §10.1)

The rendered tree is derivable from the model (`view` is pure), so a
session that has no connected host does not need it.

- Each session has an unguessable id (128 bits from `Std.SecureRandom`),
  sent to the host at start (`{"t":"session","id":...}`). The host keeps it
  in memory for the page's lifetime and includes it in `hello` when it
  reconnects.
- **Connected** sessions keep their tree.
- On disconnect a session is **detached**: tree and input versions are
  dropped, the model and any pending dialog kept, for
  `HostConfig.reconnectGraceMs` (default 120000). A `hello` carrying the id
  within that window re-renders from the model and resumes; afterwards the
  id is unknown and the route's `init` runs again.
- `HostConfig.maxSessions` (default 10000) bounds live sessions. When a new
  session would exceed it, expired then oldest detached sessions are
  evicted; if every session is connected the new connection gets a static
  "server busy" page and no session.
- Input versions are pruned after every render to inputs that still exist.
- All work on one session (a host message, its effects, detach, resume) is
  serialised by a per-session lock, because the WebSocket server runs each
  connection on its own thread and a reconnect can arrive while the old
  connection is still running an effect. Output goes to whichever connection
  the session is attached to when it is sent.
- A per-session byte cap is not provided: it cannot be measured without
  serialising the model.

### Q-UI-009 — Structured field paths and stable list rows (§11)

`FieldError` identifies its field by a `FieldPath`, a list of segments
`Named(name)` and `Item(id)`, instead of a dotted string. Rows of a
list-valued field are held in `DraftRows[D]`, which gives each row an id
from a counter inside the draft (deterministic, so `update` stays pure).
Errors, widget keys and edits all address a row by that id, so they stay
attached to the right row when rows are added, removed or reordered. Index
paths (`lines.2.qty`) are rejected for the same reason as in Q-UI-005.
`Forms.Parse` helpers take a `FieldPath`. Generator support for `List[T]`
fields (repeater derivation, list-level invariants) waits for Q-UI-004.

## Designs recorded for later phases

### Q-UI-002 — `Ctx[A] = { ui: UiCtx, app: A }` (§6.4)

The library owns the part of the context it reads itself, `UiCtx` (locale,
time zone, display density); the application supplies the rest as a type
parameter `A` (user, permissions, tenant, feature flags). `Screen` gains
that one parameter. A fixed record with an untyped extension slot was
rejected (stringly typed), and a purely application-defined context was
rejected because library widgets could not format dates or numbers for the
user's locale. Context changes go through the pure session reducer (§6.4),
which the application writes over `A`.

### Q-UI-003 — Package-level purity rules (§5.5)

Enforced by the `[layers]` feature, without effect inference:

- A `@pure` package may not declare a module-level `var`, a module-level
  `val` of a mutable type (`List`, `Map`, a protected type), or create a
  protected-type instance at module level (`Y0007`).
- Code in `pure`, `logic` and `view` layers may not call a protected-type
  `entry` (`Y0008`).

Because restricted layers may only import pure or layered packages, both
rules are transitive by construction. Inferring "touches global mutable
state" as an effect through the call graph was rejected as a large checker
change for little additional precision. In-place mutation of a list inside
the model passed to `update` is aliasing, not hidden state, and is left to
a future lint.

### Q-UI-004 — Generator request schema version 2 (§11.4)

The `@generate` request currently sends no annotations (`"annotations":[]`
for the type and every field), no invariants and no type parameters, so
`Forms.Derive` cannot be written against it. Schema version 2 adds type and
field annotations (name plus raw argument text), type parameters, and each
invariant as source text with its span and optional `@message`. Invariants
travel as source text rather than structured AST: the generator copies them
into `validate`, where parsed fields are bound to locals of the same names,
and the generator SDK stays decoupled from the compiler's AST. Generators
declaring schema version 1 keep receiving the version 1 shape. Parser
support for `invariant: expr @message("...")` is verified as part of that
work.

### Q-UI-006 — Gate `raw` behind a feature (§7.3)

`raw` is declared under `@cfg(feature = "html")` in `lyric-ui`, on by
default; a build for a host that cannot render HTML disables the feature.
This uses the existing feature mechanism (D045) and needs no UI-specific
manifest table or compiler knowledge of `lyric-ui`. The resulting error is
currently an unknown-name error; `@cfg` is to report "`raw` requires feature
`html`" for any item erased by an inactive feature, which benefits every
`@cfg` user. Implemented together with `Raw` itself and the first non-HTML
host (§13.3).

### Q-UI-008 — JVM desktop host uses the C `webview` library (§10.2)

The JVM desktop host binds the same C `webview` library as the MSIL and
native hosts, through the Java foreign function API (JDK 22+) or JNI if the
JVM baseline stays at JDK 21. JavaFX `WebView` was rejected: it is a
separate OpenJFX dependency, its WebKit lags the system engines, and it
would be a third rendering engine to test against. The more immediate JVM
gap is that `lyric-ui` does not build on JVM at all (#7378).

### Q-UI-010 — Generate the runtime's widget schema, not the renderer (§10.3)

`runtime/src/schema.ts` (widget kinds, prop names and allowed values, event
names) is generated from `Ui.Core`/`Ui.Widgets` and imported by the
hand-written renderer, so protocol drift fails `tsc`; CI checks the
generated file is current, as it does for the embedded assets. The renderer
itself (DOM construction, accessibility, input coalescing) stays
hand-written: generating it would move behaviour into a code generator
without removing any of it.
