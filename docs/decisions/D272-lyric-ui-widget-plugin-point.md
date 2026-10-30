# D272 - The lyric-ui widget plugin point (docs/69 P6, first half)

**Status:** shipped. Extends D137/D138 (docs/65) and D207/D228 (docs/69);
implements the widget half of docs/69 §16 P6. Trusted mode, the other half,
stays open.

## Context

`lyric-ui` has a closed set of semantic widgets (docs/65 §7.1), and docs/69 §1
names third-party widgets as one of the cases plugins exist for. The direction
was decided before this entry: a widget plugin implements a point whose methods
take state and events and return views, and the host renders those views with
its own widgets. That keeps the model-view-update architecture and works out of
process. What remained was the shape of the point, where widget state lives,
how a `View` crosses a boundary that rejects closures, how a screen places a
plugin widget, and how failures render.

`Ui.Core.View[Msg]` cannot cross as it is. It is generic, and its `Handler`
cases (`OnInput`, `OnChange`, ...) and `Lazy` hold closures. K0001 rejects
both, and the rule is right: a call cannot carry code.

## Decision

1. **The point.** `Ui.Plugins` (`lyric-ui/plugins/`, a library that depends
   only on the standard library) declares
   `@plugin_point(version = "1.0", contributions = WidgetContributions) pub interface WidgetPlugin`
   with three methods. Each returns `Result[WidgetStep, WidgetError]`:
   - `init(WidgetInit)` gets the widget name, the instance name and the
     configuration;
   - `update(WidgetUpdate)` also gets the state and a `WidgetMessage`;
   - `configure(WidgetConfigure)` re-renders the state for a configuration
     that may have changed, and serves the host's Retry.

   A `WidgetStep` is `{state, view, outcomes}`. One answer carries the next
   state and the view, so an interaction costs one round trip (docs/69
   Q-PLG-008's batching guidance).
2. **The host keeps the state.** `state` is a `JsonValue` the plugin returns
   and the host passes back on the next call. The plugin keeps nothing between
   calls.
   - A crashed plugin is restarted by `Std.Plugin` on the next call and
     continues from the last state it returned. The end-to-end test checks
     this.
   - A screen's state stays replayable (docs/65 §4.5), and a widget behaves the
     same whichever payload runs it.
   - The rejected alternative kept state in the plugin process, keyed by an
     instance id the host allocates. A restart would lose it, and the host
     would have to tell the plugin when an instance goes away. The cost of the
     chosen design is that the state crosses the boundary on every call, and
     the plugin writes its own state codec.
3. **`WidgetTree`, the boundary form of a view.** It is a non-generic union
   (`TreeNode`, `TreeText`, `TreeEmpty`) with no closures.
   - A `NodeHandler` names an event (`Click`, `Input`, `Change`, `Submit`)
     and a message string.
   - `NodeKind` is `WidgetKind` without the host-owned widgets. A data grid's
     rows are fetched by the screen's effects, and dialogs and toasts are UI
     effects.
   - `Lazy` has no counterpart.

   The host converts a tree into a real `View` (`Ui.PluginWidgets.treeView`).
   Each handler becomes a host closure that produces a
   `WidgetSignal.WidgetEvent(instance, message, data, coalesce)`. No boundary
   rule was relaxed. `Ui.Plugins.Build` gives plugin authors the
   `Ui.Widgets` builders with the same properties, taking message strings in
   place of messages.
4. **Plugin calls are effects.** A screen holds a `PluginWidget` per placement
   in its model. `Ui.PluginWidgets` is pure, and the `ui` layer preset lets
   logic, effects and views import it:
   - `placeWidget` starts a placement;
   - `signalWidget` applies a signal and `reconfigureWidget` a new
     configuration;
   - `replyWidget` applies a reply.

   Each returns a `WidgetChange`: the new placement, at most one
   `WidgetRequest` and the widget's outcomes. The effect interpreter runs a
   request with `Ui.PluginWidgets.Host.runWidgetRequest`, which the preset
   allows only in effects. The reply comes back as a message, so `update` and
   `view` stay pure.

   One request per placement is in flight at a time:
   - Later signals wait in a queue of at most 64. A text-input event replaces
     a waiting one for the same message, and a configure waits once.
   - Each `update` therefore sees the state the previous one returned.
   - A reply is matched by sequence number, so a stale reply is dropped.
5. **Outcomes, not effects.** A widget cannot navigate, open dialogs, show
   toasts or do I/O. It returns `WidgetOutcome { name, payload }` values,
   which the embedding screen interprets as it likes (docs/65 §6.2's outcomes,
   as data).

   Version 1.0 of the point allows no capabilities:
   - A widget computes from what the host passes in, so it is deterministic.
   - A wasm payload runs it with no access to anything.
   - Data a widget needs arrives in its configuration, which the screen
     changes with `reconfigureWidget`.

   An application whose widgets need host services can declare its own point
   with `allows(...)` over the same `Ui.Plugins` boundary types. The host-side
   runner for such a point is not part of this entry.
6. **Contributions.** `WidgetContributions { widgets: List[WidgetDecl] }`. A
   `WidgetDecl` has `name`, `title`, `description`, `configSchema` (a JSON
   Schema 2020-12 document) and `defaultConfig`.
   - `widgetCatalog(host)` lists every declared widget from the manifests
     without starting a plugin.
   - `runWidgetRequest` refuses a widget the plugin does not declare.
   - The schema describes the configuration for tools and for applications
     that let a user configure a widget. The host does not validate it: the
     plugin answers a bad configuration with `InvalidConfig`.
7. **Embedding and failure.** `widgetView(w, toMsg)` returns a column keyed by
   the instance name. It holds:
   - a loading indicator while the placement starts (key `status`);
   - an error banner and a Retry button while it is broken (keys `status`
     and `retry`);
   - the plugin's last view, under a column keyed `view`, so the plugin's
     keys cannot collide with the screen's.

   Every failure keeps the last good state and view, shows the banner, and
   drops the waiting signals:
   - the plugin's `WidgetError`;
   - a boundary error: `Timeout` (bounded by the host's `callTimeoutMs`),
     `Crashed`, `Protocol`, ...;
   - a plugin that is not loaded, or a widget it does not declare;
   - a view the host refuses.

   Retry sends `configure` for a placement that has started and `init` for
   one that has not. A failing widget never breaks the screen.
8. **The host distrusts the tree.**
   - **Limits.** A view may have at most 2000 nodes, 32 levels and 262144
     characters (`maxTreeNodes`, `maxTreeDepth`, `maxTreeChars`).
   - **Properties.** Names outside the semantic widgets' set are dropped, and
     only the first of each name is kept. A link keeps its `href` only when it
     is an application path (`/x`, not `//x`) or an `http`/`https` URL with no
     control characters or backslashes. The web runtime sets `href` as an
     attribute, so a `javascript:` URL from a plugin would otherwise run
     script in the application's page.
   - **Handlers.** A node keeps one handler per event.
9. **Concurrency.** The UI hosts run effects concurrently (D148), and
   `Std.Plugin` serves one plugin from one thread. `WidgetRunner` (from
   `newWidgetRunner(host)`) holds a lock per plugin around each call, so calls
   to different plugins still run in parallel.
10. **Packaging.** A widget plugin depends on two small libraries, both of
    which need only the standard library, so it builds for every target:
    - `Ui.Plugins` (`lyric-ui/plugins`), the point and its boundary types;
    - `Ui.Plugins.Build` (`lyric-ui/plugins/build`), the builders.

    It does not depend on `Lyric.Ui`, which pulls in `lyric-web` and
    `lyric-ws`. The host side, `Ui.PluginWidgets` and
    `Ui.PluginWidgets.Host`, is in `Lyric.Ui`, which depends on
    `Ui.Plugins` only.

    The builders are a library of their own because their names are
    `Ui.Widgets`' names (`field`, `button`, `select`, ...). In one
    bundle, a body specialised from another package (`Ui.Forms` calling
    `field`) could not choose between the two declarations; the JVM failed
    with `NoSuchMethodError`. Mono resolving such calls by the declaring
    package's imports is the real fix and is tracked separately.

## Compiler defects found on the way

Both are fixed here.

- **`Lyric.Mono`: qualified call taken for a generic.** A qualified call to a
  non-generic function, such as `Build.button("Add", "inc")`, was
  specialised as a call to a same-named generic in another package
  (`Ui.Widgets.button[Msg]`) when the arguments fit it. The call then built a
  `View` where a `WidgetTree` was expected (an `ArrayTypeMismatchException`
  or `InvalidProgramException` on dotnet).
  - The fallback that matches a qualified call's last segment against
    `genDecls` now leaves the call alone when the qualifier names a package
    the file imports and the generic was declared in another one
    (`qualifierNamesOtherImportedPkgMono`).
  - Covered by a `mono_self_test.l` case.
- **`Lyric.PluginExpand`: `JsonValue` decoder on native.** A `JsonValue`
  boundary field decoded through an inline `Ok(value = j)` inside a `match`.
  Native codegen cannot infer that `Ok`'s error type (N0007), so no plugin
  with a `JsonValue` field built for `--target native`. The decoder is now
  the typed helper `__pluginDecJson`.

- **MSIL: enums of a restored dependency in signatures.** A restored
  artifact's enums were registered in the member pass, artifact by artifact.
  A function of an earlier artifact whose signature names a later artifact's
  enum (`Ui.PluginWidgets.hostKind(Ui.Plugins.NodeKind)` in `Ui.dll`) was
  therefore encoded with a class reference instead of `int32`, and the call
  failed with `Method not found` at run time.
  - `registerRestoredArtifactTokens` now registers every artifact's enums
    before it encodes any member.
  - The dotnet host of the end-to-end test and the review example's tests
    cover it.

## Consequences

- `examples/plugins/ui-widgets/` has two parts:
  - `widgets` is a plugin with a `rating` and a `tags` widget;
  - `review` is a layered screen that places them and is served on the web
    host. Its logic and view tests run without a plugin process.
- `lyric-ui/plugins/e2e/` (a host program and the misbehaving
  `test.flaky-widgets` fixture) and `scripts/ci/ui-widget-plugins-e2e.sh`
  drive real plugin processes through `Ui.Host.instance`. They check the
  views, outcomes, event routing and queueing, and how an error, a crash, a
  timeout and an oversized view render and recover.
  - Every pair of a dotnet, JVM or native host with dotnet, JVM or native
    payloads passes, and so does a dotnet host with wasm payloads.
  - The native UI renderer (`lyric-ui/native`) takes the same `route` and
    so shows plugin widgets unchanged. Its headless golden-frame harness needs
    SDL3 and a Vulkan driver, and no plugin-widget scene has been added to it.
- The `ui` layer preset (`Lyric.Layers.presetRules`, docs/01 §9.4) gains
  `Ui.PluginWidgets` for logic, effects and views, and
  `Ui.PluginWidgets.Host` for effects.
- docs/69 §16 P6 is split: the widget point is done, trusted mode (§10) stays
  open.
