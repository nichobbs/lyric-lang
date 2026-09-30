# Browser end-to-end test for the UI host; a direct async call awaits in place on dotnet (#7836, #7838)

**Browser end-to-end test (#7836).** `scripts/ci/ui-browser-e2e.sh --target
dotnet|jvm` builds and starts `examples/ui-customers` and drives it in
headless Chromium with Playwright (`lyric-ui/runtime/e2e/customers.e2e.mjs`).
It checks three things:
- the stored customer renders;
- clearing the required name and saving marks the field invalid, and a valid
  save shows the "Customer saved" toast;
- dropping the session socket (Playwright's `routeWebSocket`) reconnects to
  the same session, with an unsaved edit still in the model.

CI runs it in the `ui` job on dotnet, and at the end of `ui-jvm-suites.sh` on
the JVM. It found two defects that the separate host and runtime suites could
not see (docs/65 §15, F-16 and F-17).

**Sibling-port WebSocket origins (F-16).** Since #7243, `lyric-ws` refuses a
cross-origin browser handshake. `Ui.Host` serves the page on `port` and the
socket on `wsPort`, so every browser handshake got 403 and the page never
left its placeholder.

`WsServerOptions.sameHostPorts` now also admits an origin whose host equals
the `Host` header's host and whose port is listed; a missing port means the
scheme's default. Both kernels apply it through
`Ws.Handshake.originAllowedFor`. `originAllowed` keeps its signature and
delegates with no ports. `Ui.Host` lists its HTTP port. `ws_handshake_tests.l`
covers the rule: a listed port, IPv6, default ports, an unlisted port, another
host, and a malformed port. #7831 (one listener) will remove the second port.

**A direct call to an `async func` awaits in place on dotnet (#7838, F-17).**
docs/01 §7.1 says a direct call awaits in place with or without `await`. MSIL
awaited only an explicit `await`, or the operand of `?` (D-progress-941).
Anywhere else the call left the kickoff's `Task<T>` in place. A lambda body
typed `(E) -> Option[Msg]` returned it, and the cast failed at run time; this
is how the example's effect replies never reached the session. A `val` bound
to it, or a `match` on it, could not bind its pattern variables (T0115).

The fix has two parts:
- The type checker records every call that binds to an `async func`
  (`SymbolTable.asyncCallSites`), from the direct signature, the method pick,
  or an async function value.
- On MSIL (`MiddleEndOptions.awaitAsyncCalls`), `Lyric.Propagate` wraps each
  such call in an explicit `EAwait`, unless it is already the operand of
  `await`, `spawn` or `?`. Every existing lowering then applies: a suspend
  point inside an `async func`, a blocking wait elsewhere.

Inside an `async func`'s own `try`/`catch`/`finally` that suspend point
cannot be lowered, so the call is rejected with the new `F0046`, as V0012 does
for a written `await`. JVM and native already awaited a direct call and are
unchanged.

`async_implicit_await_self_test.l` runs on both targets. It covers a lambda
body, a `val`, a match scrutinee, an operand and a call argument, each from a
sync and from an async caller, plus a statement call and explicit or spawned
calls, which are not awaited twice. `propagate_self_test.l` covers F0046.

**Handler failures in `lyric-ws` (F-18).** An exception thrown by a
`WsHandler` callback escaped the kernel's `invokeOnMessage` and ended the
connection's read task unobserved. Nothing was logged, so the failure above
was invisible on the server. Both kernels now catch a failing
`onOpen`/`onMessage`/`onClose`, report it to `onError` ("the onMessage
handler failed: ..."), and keep the connection. An `onError` that throws as
well goes to stderr. `ws_dotnet_e2e_tests.l` sends a message that panics the
handler, then another, and checks that the second is still echoed and the
first reached `onError`.

**The JVM kernel answers a peer's close (F-20).** Undertow's low-level
`receive()` API leaves the reply to a close frame to the application, and the
JVM kernel only drained the frame. A browser that closed its socket waited
for an answer that never came, so the runtime never reconnected. The kernel
now echoes the peer's code (or an empty close, or 1002 for a code that may
not be sent back), as the dotnet kernel does. `lyric-ws-undertow-jvm-smoke.sh`
sends a close and checks the reply.

**The example's list screen and toasts across navigation (F-19).** A save or
a cancel in the editor navigates to `/customers`, which the example did not
serve, and the "Customer saved" toast sent in the same step was lost when
the page changed.
- `examples/ui-customers` gains a list screen (`Customers.List.Logic`,
  `.Effects` and `.View`, tested in `tests/list_tests.l`).
- The runtime stashes the toasts on screen in `sessionStorage` on `navigate`
  or `back`, and shows them again once the next page loads
  (`runtime/src/toasts.ts`, served as `/_ui/runtime/toasts.js`, with node
  tests).

**A qualified call reaches the named package's generic function.** The
arity-keyed overload slots hold non-generic signatures only, so
`UiTest.findAll(v, kind)` (`Ui.Testing`, generic) bound to `Std.Xml.findAll`
(non-generic, same arity). Qualified candidates now come from the by-name
slot, which holds every function, filtered by arity, with non-generic
signatures first. `typechecker_self_test.l` covers the alias and the
fully-qualified spelling, and checks that a wrong argument is reported
against the right signature.

**Interface default methods in contracts.** Since #7575 an imported
interface is member-complete, but `reprForInterface` dropped default methods
(`IMFunc`). A restored interface's default method was therefore reported as
unknown. The repr now carries each default with its body, in the inline form
generic bodies use, so it re-parses as a default. `contract_meta_self_test.l`
covers it.

`Lyric.Pipeline.hasErrorDiagnostic` is public, and the language server uses
it instead of its own copy (#7837 review).
