# D-progress-980 — Keyed event paths, session resume, field paths; three compiler fixes they needed (#7390)

**Status:** shipped

Implements the four D138 resolutions that affect shipped code, plus three
compiler fixes the new `lyric-ui` code and its tests needed.

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
  between the close and the detach is not undone. The generic `instance` is
  compiled into each calling package, which may link `Ui.Host` as a prebuilt
  assembly where a protected type is opaque (its entries are not callable
  across that boundary), so the generic body reaches the lock only through
  the non-generic `newInstanceLock`/`withLock`, compiled in `Ui.Host`.
- `Ui.Host.SessionRegistry` (a protected type) holds sessions by id and the
  connection each is attached to: `admit` (expire, then evict the
  longest-disconnected, else refuse; making room and adding the session
  are one entry, so concurrent connections cannot exceed the limit),
  `attach` (reconnect within
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

## Detached nodes in the TypeScript runtime

`remove` and `replace` now clear the detached node's `parent`, and
`eventPathOf(root, node)` returns `null` for a node that is no longer under
the root. An input event coalesced until the next frame for a node a patch
removed in between is not sent (before, it produced a `-1` path step that
the session rejected as a malformed message).

## Compiler: generic record fields checked in the wrong scope

`Prog(step = stepB)` where `Prog[M, Msg]` is declared in another package
and the constructing package has its own type named `Msg` failed with T0104
"field expects (<error>, Msg) -> <error>". After inferring a generic
constructor's type arguments, `inferConstruction` checked each argument
against the field type resolved *without* the record's type parameters in
scope (the list built for the missing-field check), so `M` became an error
type and `Msg` bound to the consumer's type. It now checks against the
parameter-aware field types from `ctorFieldTypes`, instantiated at the
inferred arguments (`instantiatedFieldType`). `ctorFieldTypes` now resolves
under the declaring package's scope, as `collectCtorFields` already did for
#6689, so a field type naming the declaring package's own type does not
bind to a same-named type of the constructing package. Regression:
`emitter_project_self_test.l` "a generic record parameter named like a
consumer type" on both targets.

## Compiler: invoking an un-annotated function-typed lambda parameter on MSIL

`val g: (() -> Bool) -> String = { p -> if p() then ... }` took the `then`
branch for `p` returning `false`. An un-annotated lambda parameter takes its
logical type from the lambda's expected type (`lambdaParamTypes`), but only
as the erased delegate shape; the parameter's own return type was never
registered in `funcValRetTypes`, so `p()` stayed a boxed `object` and the
condition tested it for non-null. The return type of each function-typed
parameter is now recorded where lambda parameter types are propagated (a
`val` annotation, and a lambda passed to a function-typed parameter, whose
own function-typed parameters' return types are recorded unless they
mention the declaring function's type parameters) in
`lambdaParamFnRetTypes`, and registered when
the lambda body's parameters are set up. Independently of where the
value comes from, MSIL now unboxes a Boolean operand that arrives as a boxed
`object` at every consumer (`lowerBoolOperandMsil`: `if`/`while`
conditions, `and`/`or`/`implies`/`xor`, `not`, match guards), so a producer that
does not track its return type (for example a generic callback returning
`T` with `T = Bool`) cannot turn a boxed `false` into a taken branch. The
JVM backend already coerced conditions in `lowerBoolCond`, except for match
guards, which branched on the raw reference and failed verification
(`VerifyError: Bad type on operand stack`); guards now go through
`lowerBoolCond` too. The value-producing operators (`and`/`or`/`implies`
bound to a local rather than branched on, and `xor`) lowered their operands
without coercion on JVM, and `xor` on MSIL as well; both backends now coerce
them (`lowerBoolValue` on JVM), and `xor` is typed `Bool` rather than `Int`
in both. Regression: `lambda_bool_if_cond_self_test.l` cases 5 to 8 on both
targets.

## Tests

`lyric-forms` 11 (4 new), `lyric-ui` suites extended for keyed rows,
echoes, detach/resume, the instance lock and the registry, TypeScript
runtime 7 (`eventPathOf`).
