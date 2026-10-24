//! Ui.Plugins — the widget plugin point of `lyric-ui` (docs/69 §16 P6,
//! docs/65 §6.5).
//! Stability: @experimental.
//!
//! A widget plugin adds widgets to an application without running in its
//! process.  It is a plugin of point `WidgetPlugin`: the host calls it with a
//! widget's configuration, its state and the message an interaction produced,
//! and it answers with the next state and a view, as a `WidgetTree`.  The host
//! keeps the state and renders the tree with its own semantic widgets
//! (`Ui.PluginWidgets`), so a widget looks like the rest of the application on
//! every host, survives a restart of its plugin, and never runs code in the
//! host.
//!
//! A widget plugin is a model-view-update screen in miniature:
//!
//!   - `init(WidgetInit)`: the first state and view for a configuration;
//!   - `update(WidgetUpdate)`: the next state and view after a message;
//!   - `configure(WidgetConfigure)`: the view again for a new configuration
//!     (or the same one, when the host retries after a failure).
//!
//! Each returns a `WidgetStep`.  Its `state` is the plugin's own, opaque to
//! the host and returned on the next call; its `outcomes` are requests to the
//! embedding screen, as data (docs/65 §6.2).  The point allows no
//! capabilities: a widget computes from what the host passes in, and asks for
//! anything else through outcomes, so it is deterministic, and a wasm payload
//! runs it with no access to anything.
//!
//! A `WidgetTree` is a `Ui.Core.View` without closures: each handler names an
//! event and a message string, which the host sends back as the
//! `WidgetMessage` of the next `update`.  `Ui.Plugins.Build` builds trees with
//! the same builders as `Ui.Widgets`.
//!
//! This package depends only on the standard library, so a widget plugin
//! builds for every target, wasm32-wasi included.  `Lyric.PluginExpand`
//! generates the codecs, `WidgetPluginRemote`, `widgetPluginRemotes`,
//! `widgetPluginContributions` and `pluginDispatchWidgetPlugin` here.
@runtime_checked
@io
package Ui.Plugins

import Std.Core
import Std.Collections
import Std.JsonValue

// ─── Views ────────────────────────────────────────────────────────────────────
/// The semantic widgets a plugin's view may use: `Ui.Core.WidgetKind` without
/// the host-owned ones.  A data grid's rows are fetched by the embedding
/// screen's effects, and dialogs and toasts are effects the UI runtime
/// interprets, so a widget asks for those through outcomes instead.
pub enum NodeKind {
  case Column
  case Row
  case Card
  case Section
  case Spacer
  case Heading
  case Paragraph
  case Label
  case Badge
  case TextInput
  case TextArea
  case NumberInput
  case Checkbox
  case Select
  case SelectOption
  case DateInput
  case Button
  case Link
  case Banner
  case Spinner
  case FieldError
  case Table
  case TableRow
  case TableCell
  case Form
  case Field
}

/// The events a node can answer to.  `Input` and `Change` carry the text the
/// user entered (or `"true"`/`"false"` for a checkbox) as the message's data;
/// `Click` and `Submit` carry none.
pub enum NodeEvent {
  case Click
  case Input
  case Change
  case Submit
}

/// A widget property, as in `Ui.Core.Prop`.
pub record NodeProp {
  name: String
  value: String
}

/// What an event on a node produces: the `message` the host sends back in a
/// `WidgetMessage`.
pub record NodeHandler {
  event: NodeEvent
  message: String
}

/// A widget's view.  An empty `key` means unkeyed, as in `Ui.Core.View`.
pub union WidgetTree {
  case TreeNode(kind: NodeKind, key: String, props: List[NodeProp], handlers: List[NodeHandler], children: List[WidgetTree])
  case TreeText(text: String)
  case TreeEmpty
}

// ─── Calls ────────────────────────────────────────────────────────────────────
/// A message produced by an event on a widget's view: the handler's
/// `message` and the event's data (empty for clicks and submits).
pub record WidgetMessage {
  message: String
  data: String
}

/// Start widget `widget` (a name from the plugin's `WidgetContributions`) as
/// instance `instance` with `config`.  `instance` is the host's name for this
/// placement; it is stable while the screen shows the widget, and a plugin
/// may use it in logs, never as a key to state of its own.
pub record WidgetInit {
  widget: String
  instance: String
  config: JsonValue
}

/// Apply `message` to `state`, the state the plugin returned last for this
/// instance.
pub record WidgetUpdate {
  widget: String
  instance: String
  config: JsonValue
  state: JsonValue
  message: WidgetMessage
}

/// Render `state` again for `config`, which may have changed since the
/// state was returned.
pub record WidgetConfigure {
  widget: String
  instance: String
  config: JsonValue
  state: JsonValue
}

/// A request to the screen that embeds the widget: `name` says what, in the
/// widget's own vocabulary, and `payload` carries the details.  The screen
/// decides what each means; a widget cannot navigate, open dialogs, show
/// toasts or do I/O itself.
pub record WidgetOutcome {
  name: String
  payload: JsonValue
}

/// The result of a widget call: the next state (`JNull` is a valid state),
/// the view to show and the outcomes for the embedding screen.
pub record WidgetStep {
  state: JsonValue
  view: WidgetTree
  outcomes: List[WidgetOutcome]
}

/// Why a widget call failed.
pub union WidgetError {
  case UnknownWidget(widget: String)
  case InvalidConfig(detail: String)
  case InvalidState(detail: String)
  case WidgetFailed(detail: String)
}

/// A sentence describing `e`.
pub func widgetErrorMessage(e: in WidgetError): String {
  match e {
    case UnknownWidget(w) -> "the plugin has no widget named '" + w + "'"
    case InvalidConfig(d) -> "invalid configuration: " + d
    case InvalidState(d) -> "invalid state: " + d
    case WidgetFailed(d) -> d
  }
}

// ─── Contributions ────────────────────────────────────────────────────────────
/// A widget a plugin provides, read from its manifest without starting it.
/// `name` is unique within the plugin.  `configSchema` is a JSON Schema
/// (2020-12) document describing the configuration `init` accepts, for
/// tools and for applications that let a user configure a widget;
/// `defaultConfig` is a configuration it accepts as is.
pub record WidgetDecl {
  name: String
  title: String
  description: String
  configSchema: JsonValue
  defaultConfig: JsonValue
}

/// The widgets a plugin provides.
pub record WidgetContributions {
  widgets: List[WidgetDecl]
}

// ─── The point ────────────────────────────────────────────────────────────────
/// A plugin that provides widgets.  Every method answers for one instance of
/// one widget; the plugin keeps nothing between calls that the host does not
/// pass back, so a restarted plugin continues where the last one stopped.
@plugin_point(version = "1.0", contributions = WidgetContributions)
pub interface WidgetPlugin {
  func init(req: in WidgetInit): Result[WidgetStep, WidgetError]
  func update(req: in WidgetUpdate): Result[WidgetStep, WidgetError]
  func configure(req: in WidgetConfigure): Result[WidgetStep, WidgetError]
}
