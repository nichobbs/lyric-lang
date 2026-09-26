# D-progress-979 — Keyed event paths, session resume, field paths; cross-package protected-type construction on MSIL

**Status:** shipped

Implements the four D138 resolutions that affect shipped code, plus a
compiler fix the session registry needed.

## Q-UI-005: keyed event paths (protocol version 2)

`Ui.Protocol.Event.path` is a `List[NodeRef]` (`At(index)` or
`Keyed(key)`); on the wire a step is a number or a string. The TypeScript
runtime sends a node's key when it has one (`eventPathOf`). The session
resolves a key only when exactly one sibling carries it (`resolveRefs`), so
an event for a row that moved still reaches it and one for a row that has
gone is dropped. Input versions are stored against the event path
(`InputVersion { key, path, version }`, keyed by the length-prefixed
`refsKey`), pruned after every render to inputs that still exist, and turned
into per-patch `ValueEcho`s (`Output.echoes`) for the `value` props in that
step's patches.

## Q-UI-007: session memory and reconnect

- `Ui.Session.detach` drops the tree and input versions and keeps the model
  and dialog; `resume` renders from the model under a new render version.
- `Ui.Host.Instance` gains `detach(stillDetached)` and `resume(outbox)`;
  every instance operation runs inside a per-instance `InstanceLock` entry,
  because `lyric-ws` runs each connection on its own thread. `detach` checks
  `stillDetached()` under that lock, so a reconnect that resumed the session
  between the close and the detach is not undone.
- `Ui.Host.SessionRegistry` (a protected type) holds sessions by id and the
  connection each is attached to: `admit` (expire, then evict the
  longest-disconnected, else refuse), `add`, `attach` (reconnect within
  the grace period, moving a session off a connection that has not closed
  yet), `release` (only the connection currently carrying the session
  detaches it). It lives in `Ui.Host` so the desktop host can reuse it.
- `Ui.Host.Web` sends `{"t":"session","id":...}` (128 bits from
  `Std.SecureRandom`, hex) at start, resumes on `hello` with `sid`, and adds
  `HostConfig.reconnectGraceMs` (default 120000) and `maxSessions` (default
  10000). Output goes to whichever connection the session is attached to
  when it is sent (`SessionOutbox`). A second `hello` on one connection
  releases its previous session.

## Q-UI-009: field paths and list rows

`Forms.FieldError` cases carry a `FieldPath` (`Named(name)` / `Item(id)`
segments) with `fieldPath`, `child`, `item`, `rootPath`, `samePath`,
`isWithin`, `pathText` and `errorsWithin`. `Forms.Parse` helpers take a
`FieldPath`. `DraftRows[D]` gives rows ids from a counter in the draft
(`emptyRows`, `rowsOf`, `addRow`, `removeRow`, `updateRow`, `moveRow`,
`findRow`, `validateRows`). `Ui.Forms.formFieldsAt` / `fieldViewAt` render a
form nested at a base path.

## Q-UI-001

`Step` stays a record; docs/65 §4.1 and §6.3 now name the real helpers
(`stay`, `step1`, `stepAll`).

## Compiler: constructing another package's protected type on MSIL

`SessionRegistry()` called from `Ui.Host.Web` failed with T0123 "unresolved
call". MSIL registers each nominal type's short name as a cross-package
resolution candidate (`registerTypeFqnCandidate`) in three places (the
per-package token pass, the bundle-wide pre-registration, and the bridge's
restored-package pass), and all three covered records, unions, enums,
interfaces, opaque and distinct types but not protected types. All three now
register `IProtected`. The JVM backend already resolved it. Regression:
`emitter_project_self_test.l` "constructs another package's protected type"
on both targets.

## Tests

`lyric-forms` 11 (4 new), `lyric-ui` suites extended for keyed rows,
echoes, detach/resume, the instance lock and the registry, TypeScript
runtime 7 (`eventPathOf`).
