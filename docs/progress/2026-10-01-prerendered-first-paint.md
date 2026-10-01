# Prerendered first paint (docs/65 §13.4, D152)

The first slice of phase U6: the web host now puts each page's first
view in its HTML, so first paint no longer waits for the WebSocket.

- **Page request.** `Ui.Host.Web`'s shell handler starts the session for
  the requested URL as a disconnected session. It renders the session's
  view with the new pure `Ui.Html` package and embeds the session id as
  `data-sid`. The response carries `Cache-Control: no-store`.
- **Runtime.** It quotes `data-sid` in its first `hello`, and the existing
  resume path swaps in the live tree, so `init` and its effects run once.
  `aria-busy` now clears when the first patch is applied, not when the
  socket opens.
- **`Ui.Html`** renders a `WireNode` with the same elements, classes,
  roles and ARIA wiring as the runtime's `DomRenderer`.
- **API:**
  - `HostConfig.prerender` (default `true`);
  - `Instance.snapshot()`;
  - `SessionRegistry.admit` with an empty connection id admits a
    disconnected session;
  - `shellHtml` takes the session id and the first view.

- **Eviction.** A full registry evicts never-claimed prerendered sessions
  before any session a browser was using (`SessionEntry.claimed`), so page
  loads that never connect cannot push out a user who is reconnecting.
- **JVM `max_stack` fix.** The assembler reset its tracked stack depth to 0
  at every label. A comparison materialised as a constructor argument
  inside another call branches with that call's arguments still on the
  stack, so `max_stack` came out too small and the class failed
  verification (`Operand stack overflow`, first hit by `admit` above).
  Branches now record the depth at their target, and a label starts at the
  deepest incoming edge (`noteBranch`, `enterLabel`).

Tests:
- `html_tests.l` (field, label and error wiring, checkbox, select,
  chrome, deterministic ids);
- `host_tests.l`: the shell with a prerendered session, `snapshot`,
  eviction order and `pageUrl`;
- `silent_miscompile_guard_jvm_self_test.l`: a nested comparison
  constructor argument verifies;
- the browser e2e gains "the page arrives prerendered, then the session
  takes over", on dotnet and the JVM;
- the `lyric-ui` suites pass on both targets.

Still to come in U6: `Lazy` subtrees and the data grid.
