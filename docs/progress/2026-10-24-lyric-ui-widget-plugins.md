# Plugins P6 (first half): the lyric-ui widget plugin point (D272)

- **The point** (`lyric-ui/plugins`, package `Ui.Plugins`):
  - `WidgetPlugin` 1.0 has `init`, `update` and `configure`, each returning a
    `WidgetStep`: the next state as JSON the host keeps, the view as a
    `WidgetTree`, and `WidgetOutcome`s for the screen.
  - Contributions are `WidgetContributions`: a `WidgetDecl` per widget with
    its name, title, description, the JSON Schema of its configuration and a
    default configuration.
  - The point allows no capabilities.
- **Plugin side** (`lyric-ui/plugins/build`, package `Ui.Plugins.Build`): the
  `Ui.Widgets` builders, producing `WidgetTree`s with message strings.
- **Host side** (`Lyric.Ui`):
  - `Ui.PluginWidgets` (pure):
    - placements are `PluginWidget`s, driven by `placeWidget`,
      `signalWidget`, `reconfigureWidget` and `replyWidget`;
    - one request is in flight per placement, with a bounded queue that
      coalesces input events, and stale replies are dropped;
    - `widgetView` converts a tree into a `View`, keyed by the placement's
      instance name, and shows a loading indicator, or an error banner with
      a Retry button;
    - a view is checked against size limits, its properties are filtered and
      unsafe links lose their `href`.
  - `Ui.PluginWidgets.Host` (I/O): `WidgetRunner` takes a lock per plugin;
    `runWidgetRequest`, `widgetCatalog` and `findWidget`.
- **Layers:** the `ui` preset lets logic, effects and views import
  `Ui.PluginWidgets`, and effects import `Ui.PluginWidgets.Host`
  (`Lyric.Layers`, docs/01 §9.4).
- **Example:** `examples/plugins/ui-widgets`.
  - `widgets` is the plugin `example.ui-widgets`, with the `rating` and `tags`
    widgets.
  - `review` is a layered screen that places both widgets and is served on
    the web host. Its tests run without a plugin process.
- **End to end:** `scripts/ci/ui-widget-plugins-e2e.sh`.
  - It packs the example plugin and the `test.flaky-widgets` fixture
    (`lyric-ui/plugins/e2e/flaky`) and checks both artifacts.
  - It runs `lyric-ui/plugins/e2e/host`, a screen of four placements driven
    through `Ui.Host.instance`. The checks cover the catalog, the first views,
    a missing plugin, event paths to buttons and inputs, outcomes, queueing,
    and a plugin error, crash, timeout and oversized view, each with its
    recovery. The state survives a plugin restart.
  - It is wired into `scripts/ci/plugin-suites.sh` (dotnet and JVM pairs),
    `scripts/ci/native-backend-self-tests.sh` (native pairs) and
    `scripts/ci/wasm32-wasi-rt-tests.sh` (wasm payloads under a dotnet host).
- **Compiler fixes:**
  - `Lyric.Mono` no longer specialises a qualified call into one imported
    package as a same-arity generic of another.
  - `Lyric.PluginExpand` decodes a `JsonValue` field through a typed helper,
    so a plugin with one builds for `--target native`.
  - The MSIL backend registers every restored artifact's enums before it
    encodes member signatures, which fixes `Method not found` for a function
    whose signature names another dependency's enum.
- **Tests:**

  | Suite | dotnet | JVM | native |
  |---|---|---|---|
  | `lyric-ui` (`Ui.PluginWidgetTests`: 17 cases) | 11/11 suites | 9/11 suites; `HostTests` and `DesktopTests` need the restored Undertow jars, which this machine cannot resolve | — |
  | `Ui.Plugins.Build.Tests` | 13/13 | 13/13 | — |
  | `Review.Tests` | 4/4 | 4/4 | — |
  | `mono_self_test.l` | 121/121 | — | — |
  | `layers_self_test.l` | 32/32 | — | — |
  | `plugin_expand_self_test.l`, `plugin_codec_self_test.l` | 43/43, 6/6 | — | — |
  | `ui-widget-plugins-e2e.sh` (17 checks) | 17/17 with dotnet, JVM, native and wasm (wasmtime 49.0.3) plugins | 17/17 with dotnet, JVM and native plugins | 17/17 with dotnet, JVM and native plugins |
  | `plugin-generated-e2e.sh` (dotnet host, native plugin, after the `JsonValue` decoder change) | 8/8 | — | — |
