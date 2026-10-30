//! Ui.PluginWidgets — widgets from plugins, placed in a screen
//! (docs/65 §6.5, docs/69 §16 P6).
//! Stability: @experimental.
//!
//! A plugin widget is a `Ui.Plugins.WidgetPlugin` running out of process.  A
//! screen holds one `PluginWidget` per placement in its model, and drives it
//! the model-view-update way, with every plugin call an effect:
//!
//!   - `placeWidget` starts a placement and returns the `init` request;
//!   - the view shows it with `widgetView`, which turns the plugin's
//!     `WidgetTree` into a `View` and its handlers into `WidgetSignal`s;
//!   - `signalWidget` applies a signal and returns the request to send;
//!   - the screen's effect interpreter runs each `WidgetRequest`
//!     (`Ui.PluginWidgets.Host.runWidgetRequest`) and returns its
//!     `WidgetReply` as a message;
//!   - `replyWidget` applies the reply: the new state and view, the
//!     widget's outcomes for the screen, and the next queued request.
//!
//! The host keeps the widget's state, so a plugin that crashes and is
//! restarted continues from the last state it returned.  One request per
//! placement is in flight at a time; signals that arrive meanwhile wait in a
//! bounded queue, so every `update` sees the state the previous one
//! returned.  A failed call (the plugin's own error, a timeout, a crash, or
//! a view the host refuses) leaves the last good state and view in place and
//! shows an error banner with a Retry button above them.
//!
//! A plugin's view is checked before it is shown: at most `maxTreeNodes`
//! nodes, `maxTreeDepth` levels and `maxTreeChars` characters of text and
//! properties.  Properties other than those the semantic widgets use are
//! dropped, and a link keeps its `href` only when it is an application path
//! or an `http`/`https` URL.  The plugin's tree sits under a node keyed by
//! the placement's instance name, so its keys cannot collide with the
//! screen's.
//!
//! Everything here is pure: logic and view packages may import it under the
//! `ui` layer preset.
@runtime_checked
@pure
package Ui.PluginWidgets

import Std.Core
import Std.Collections
import Std.String as Str
import Std.JsonValue.{JsonValue, JNull}
import Ui.Core.{View, Element, Text, Empty, Handler, OnClick, OnInput, OnChange, OnSubmit, Prop, WidgetKind}
import Ui.Plugins.{WidgetTree, TreeNode, TreeText, TreeEmpty, NodeKind, NodeEvent, NodeProp, NodeHandler, WidgetStep, WidgetOutcome, WidgetInit, WidgetUpdate, WidgetConfigure, WidgetMessage}

// ─── Limits ───────────────────────────────────────────────────────────────────
/// The most nodes (elements, texts and empties) a plugin's view may have.
pub val maxTreeNodes: Int = 2000

/// The deepest a plugin's view may nest.
pub val maxTreeDepth: Int = 32

/// The most characters of text, keys and property values a plugin's view
/// may carry.
pub val maxTreeChars: Int = 262144

/// The most signals that wait while a placement's request is in flight;
/// later ones are dropped.
pub val maxQueuedSignals: Int = 64

// ─── State ────────────────────────────────────────────────────────────────────
/// Which widget a placement shows: widget `widget` of plugin `plugin`.
pub record WidgetRef {
  plugin: String
  widget: String
}

/// Where a placement stands.  `Starting` until its first `init` succeeds;
/// `Broken` after a failed call, until a later one succeeds.
pub union WidgetStatus {
  case Starting
  case Ready
  case Broken(reason: String)
}

/// Work waiting for the request in flight.
pub union PendingWork {
  case PendingMessage(message: String, data: String, coalesce: Bool)
  case PendingConfigure
}

/// One placement of a plugin widget: the host's copy of everything the
/// plugin needs, and the last view it returned.
pub record PluginWidget {
  instance: String
  source: WidgetRef
  config: JsonValue
  state: JsonValue
  started: Bool
  tree: Option[WidgetTree]
  status: WidgetStatus
  inFlight: Option[Int]
  nextSeq: Int
  queue: List[PendingWork]
}

/// What the view's handlers produce, for the screen to pass to
/// `signalWidget`.  `coalesce` marks a text-input event: a waiting one is
/// replaced by the next for the same message instead of queued behind it.
pub union WidgetSignal {
  case WidgetEvent(instance: String, message: String, data: String, coalesce: Bool)
  case WidgetRetry(instance: String)
}

/// The placement a signal is for.
pub func signalInstance(s: in WidgetSignal): String {
  match s {
    case WidgetEvent(i, _, _, _) -> i
    case WidgetRetry(i) -> i
  }
}

/// One call to a widget plugin.
pub union WidgetCall {
  case CallInit(req: WidgetInit)
  case CallUpdate(req: WidgetUpdate)
  case CallConfigure(req: WidgetConfigure)
}

/// A call to make, as an effect: run it with
/// `Ui.PluginWidgets.Host.runWidgetRequest` and pass the reply back to
/// `replyWidget`.
pub record WidgetRequest {
  instance: String
  source: WidgetRef
  seq: Int
  call: WidgetCall
}

/// The answer to a `WidgetRequest`: the plugin's step, or why the call
/// failed.
pub record WidgetReply {
  instance: String
  seq: Int
  answer: Result[WidgetStep, String]
}

/// The result of a transition: the placement's next state, the requests to
/// send (at most one) and the outcomes the widget returned for the screen.
pub record WidgetChange {
  widget: PluginWidget
  requests: List[WidgetRequest]
  outcomes: List[WidgetOutcome]
}

/// Whether a request for `w` is in flight.
pub func isBusy(w: in PluginWidget): Bool {
  match w.inFlight {
    case Some(_) -> true
    case None -> false
  }
}

// ─── Transitions ──────────────────────────────────────────────────────────────
func noOutcomes(): List[WidgetOutcome] {
  newList()
}

func unchanged(w: in PluginWidget): WidgetChange {
  WidgetChange(widget = w, requests = newList(), outcomes = noOutcomes())
}

func copyQueue(q: in List[PendingWork]): List[PendingWork] {
  val acc: List[PendingWork] = newList()
  for p in q {
    acc.add(p)
  }
  acc
}

// Send `call` now: the placement waits for its reply.
func send(
  w: in PluginWidget, call: in WidgetCall, queue: in List[PendingWork], outcomes: in List[WidgetOutcome]
): WidgetChange {
  val seq = w.nextSeq
  val next = w.copy(inFlight = Some(value = seq), nextSeq = seq + 1, queue = queue)
  val reqs: List[WidgetRequest] = newList()
  reqs.add(WidgetRequest(instance = w.instance, source = w.source, seq = seq, call = call))
  WidgetChange(widget = next, requests = reqs, outcomes = outcomes)
}

func initCall(w: in PluginWidget): WidgetCall {
  CallInit(req = WidgetInit(widget = w.source.widget, instance = w.instance, config = w.config))
}

func updateCall(w: in PluginWidget, message: in String, data: in String): WidgetCall {
  CallUpdate(
    req = WidgetUpdate(
      widget = w.source.widget,
      instance = w.instance,
      config = w.config,
      state = w.state,
      message = WidgetMessage(message = message, data = data)
    )
  )
}

func configureCall(w: in PluginWidget): WidgetCall {
  CallConfigure(
    req = WidgetConfigure(widget = w.source.widget, instance = w.instance, config = w.config, state = w.state)
  )
}

/// A new placement `instance` of `source` with `config`, and the `init`
/// request that starts it.  `instance` names the placement within its screen
/// and must be unique there; it keys the placement's node in the view.
pub func placeWidget(instance: in String, source: in WidgetRef, config: in JsonValue): WidgetChange
  requires: instance.length > 0
{
  val w = PluginWidget(
    instance = instance,
    source = source,
    config = config,
    state = JNull,
    started = false,
    tree = None,
    status = Starting,
    inFlight = None,
    nextSeq = 1,
    queue = newList()
  )
  send(w, initCall(w), newList(), noOutcomes())
}

// `q` with `work` appended, coalescing and bounding as `signalWidget`
// describes.
func enqueue(q: in List[PendingWork], work: in PendingWork): List[PendingWork] {
  val acc = copyQueue(q)
  match work {
    case PendingConfigure -> {
      for p in acc {
        match p {
          case PendingConfigure -> return acc
          case _ -> ()
        }
      }
    }
    case PendingMessage(message, _, coalesce) -> {
      if coalesce and acc.count > 0 {
        match acc[acc.count - 1] {
          case PendingMessage(lastMessage, _, lastCoalesce) -> if lastCoalesce and lastMessage == message {
            acc[acc.count - 1] = work
            return acc
          }
          case _ -> ()
        }
      }
    }
    case _ -> ()
  }
  if acc.count < maxQueuedSignals {
    acc.add(work)
  }
  acc
}

/// Apply signal `s`, from `w`'s view, to `w`.  A signal for another
/// placement is ignored.  While a request is in flight, an event waits (a
/// text-input event replaces a waiting one for the same message; beyond
/// `maxQueuedSignals` events are dropped) and a retry is ignored.  An event
/// on a placement whose `init` has not yet succeeded is ignored: it has no
/// view to have come from.  A retry starts the placement again if its `init`
/// failed, and otherwise asks the plugin for its view of the current state.
pub func signalWidget(w: in PluginWidget, s: in WidgetSignal): WidgetChange {
  if signalInstance(s) != w.instance {
    return unchanged(w)
  }
  match s {
    case WidgetEvent(_, message, data, coalesce) -> {
      if not w.started {
        return unchanged(w)
      }
      if isBusy(w) {
        return unchanged(
          w.copy(queue = enqueue(w.queue, PendingMessage(message = message, data = data, coalesce = coalesce)))
        )
      }
      send(w, updateCall(w, message, data), w.queue, noOutcomes())
    }
    case WidgetRetry(_) -> {
      if isBusy(w) {
        return unchanged(w)
      }
      if w.started {
        send(w, configureCall(w), w.queue, noOutcomes())
      } else {
        send(w, initCall(w), w.queue, noOutcomes())
      }
    }
  }
}

/// Give `w` a new configuration.  The plugin is asked for its view of the
/// current state under it (after the request in flight, if any); a
/// placement whose `init` failed is started again with it.
pub func reconfigureWidget(w: in PluginWidget, config: in JsonValue): WidgetChange {
  val next = w.copy(config = config)
  if isBusy(next) {
    return unchanged(next.copy(queue = enqueue(next.queue, PendingConfigure)))
  }
  if next.started {
    send(next, configureCall(next), next.queue, noOutcomes())
  } else {
    send(next, initCall(next), next.queue, noOutcomes())
  }
}

/// Apply reply `r` to `w`.  A reply for another placement, or for a request
/// other than the one in flight, is ignored.  A step whose view fails the
/// checks above counts as a failed call.  After a successful step the next
/// waiting signal is sent; after a failure the waiting signals are dropped,
/// since they were aimed at a view that the failure leaves in doubt.
pub func replyWidget(w: in PluginWidget, r: in WidgetReply): WidgetChange {
  if r.instance != w.instance {
    return unchanged(w)
  }
  match w.inFlight {
    case Some(seq) -> if seq != r.seq { return unchanged(w) }
    case None -> return unchanged(w)
  }
  match r.answer {
    case Ok(step) -> match treeIssue(step.view) {
      case Some(issue) -> fail(w, "the widget returned a view the host cannot show: " + issue)
      case None -> {
        val applied = w.copy(
          state = step.state,
          started = true,
          tree = Some(value = step.view),
          status = Ready,
          inFlight = None
        )
        drain(applied, step.outcomes)
      }
    }
    case Err(reason) -> fail(w, reason)
  }
}

func fail(w: in PluginWidget, reason: in String): WidgetChange {
  unchanged(w.copy(status = Broken(reason = reason), inFlight = None, queue = newList()))
}

// Send the first waiting work item of `w`, which has no request in flight.
func drain(w: in PluginWidget, outcomes: in List[WidgetOutcome]): WidgetChange {
  if w.queue.count == 0 {
    return WidgetChange(widget = w, requests = newList(), outcomes = outcomes)
  }
  val rest: List[PendingWork] = newList()
  var i = 1
  while i < w.queue.count {
    rest.add(w.queue[i])
    i = i + 1
  }
  match w.queue[0] {
    case PendingMessage(message, data, _) -> send(w, updateCall(w, message, data), rest, outcomes)
    case PendingConfigure -> send(w, configureCall(w), rest, outcomes)
  }
}

// ─── Checking a plugin's view ─────────────────────────────────────────────────
/// The record of a walk over a tree: nodes seen, characters seen, and the
/// first limit exceeded.
pub ref record TreeTally {
  var nodes: Int
  var chars: Int
  var issue: Option[String]
}

func tally(t: in WidgetTree, depth: in Int, acc: in TreeTally): Unit {
  if isSome(acc.issue) {
    return
  }
  acc.nodes = acc.nodes + 1
  if acc.nodes > maxTreeNodes {
    acc.issue = Some(value = "more than " + maxTreeNodes.toString() + " nodes")
    return
  }
  if depth > maxTreeDepth {
    acc.issue = Some(value = "nested deeper than " + maxTreeDepth.toString() + " levels")
    return
  }
  match t {
    case TreeNode(_, key, props, handlers, children) -> {
      acc.chars = acc.chars + key.length
      for p in props {
        acc.chars = acc.chars + p.name.length + p.value.length
      }
      for h in handlers {
        acc.chars = acc.chars + h.message.length
      }
      for c in children {
        tally(c, depth + 1, acc)
      }
    }
    case TreeText(s) -> {
      acc.chars = acc.chars + s.length
    }
    case TreeEmpty -> ()
  }
  if acc.chars > maxTreeChars and not isSome(acc.issue) {
    acc.issue = Some(value = "more than " + maxTreeChars.toString() + " characters")
  }
}

/// Why the host would refuse to show `t`, if it would.
pub func treeIssue(t: in WidgetTree): Option[String] {
  val acc = TreeTally(nodes = 0, chars = 0, issue = None)
  tally(t, 1, acc)
  acc.issue
}

/// Whether a plugin's link may carry `url`: an application path (`/x`, not
/// `//host`) or an `http`/`https` URL, with no control characters or
/// backslashes.
pub func safeHref(url: in String): Bool {
  var i = 0
  while i < url.length {
    val c = Str.codePointAt(url, i)
    if c == 92 or c < 32 or c == 127 {
      return false
    }
    i = i + 1
  }
  if Str.startsWith(url, "//") {
    return false
  }
  Str.startsWith(url, "/") or Str.startsWith(url, "https://") or Str.startsWith(url, "http://")
}

/// The properties the semantic widgets read.  A plugin's other properties
/// are dropped.
pub func widgetPropNames(): List[String] {
  val names: List[String] = newList()
  for n in ["busy", "checked", "disabled", "header", "href", "invalid", "label", "language", "level", "lineNumbers", "max", "maxLength", "min", "placeholder", "readonly", "required", "tabSize", "title", "tone", "type", "value", "variant"] {
    names.add(n)
  }
  names
}

/// A plugin node's properties as the host shows them: known names only,
/// the first of each name, and `href` only when `safeHref`.
pub func hostProps(props: in List[NodeProp]): List[Prop] {
  val acc: List[Prop] = newList()
  val seen: List[String] = newList()
  val known = widgetPropNames()
  for p in props {
    if known.contains(p.name) and not seen.contains(p.name) {
      if p.name != "href" or safeHref(p.value) {
        acc.add(Prop(name = p.name, value = p.value))
        seen.add(p.name)
      }
    }
  }
  acc
}

/// The host widget a plugin's node kind is shown as.
pub func hostKind(k: in NodeKind): WidgetKind {
  match k {
    case Column -> WidgetKind.Column
    case Row -> WidgetKind.Row
    case Card -> WidgetKind.Card
    case Section -> WidgetKind.Section
    case Spacer -> WidgetKind.Spacer
    case Heading -> WidgetKind.Heading
    case Paragraph -> WidgetKind.Paragraph
    case Label -> WidgetKind.Label
    case Badge -> WidgetKind.Badge
    case TextInput -> WidgetKind.TextInput
    case TextArea -> WidgetKind.TextArea
    case NumberInput -> WidgetKind.NumberInput
    case Checkbox -> WidgetKind.Checkbox
    case Select -> WidgetKind.Select
    case SelectOption -> WidgetKind.SelectOption
    case DateInput -> WidgetKind.DateInput
    case Button -> WidgetKind.Button
    case Link -> WidgetKind.Link
    case Banner -> WidgetKind.Banner
    case Spinner -> WidgetKind.Spinner
    case FieldError -> WidgetKind.FieldError
    case Table -> WidgetKind.Table
    case TableRow -> WidgetKind.TableRow
    case TableCell -> WidgetKind.TableCell
    case Form -> WidgetKind.Form
    case Field -> WidgetKind.Field
  }
}

/// A node's handlers, the first for each event.
pub func distinctHandlers(hs: in List[NodeHandler]): List[NodeHandler] {
  val acc: List[NodeHandler] = newList()
  for h in hs {
    var dup = false
    for a in acc {
      if a.event == h.event {
        dup = true
      }
    }
    if not dup {
      acc.add(h)
    }
  }
  acc
}

// ─── Views ────────────────────────────────────────────────────────────────────
/// The host handler for plugin handler `h` on placement `instance`.
pub func hostHandler[Msg](instance: in String, h: in NodeHandler, toMsg: in (WidgetSignal) -> Msg): Handler[Msg] {
  val message = h.message
  val wrap: (WidgetSignal) -> Msg = toMsg
  match h.event {
    case Click -> {
      val m: Msg = wrap(WidgetEvent(instance = instance, message = message, data = "", coalesce = false))
      OnClick(msg = m)
    }
    case Submit -> {
      val m: Msg = wrap(WidgetEvent(instance = instance, message = message, data = "", coalesce = false))
      OnSubmit(msg = m)
    }
    case Input -> OnInput(
      toMsg = { s: String ->
        wrap(WidgetEvent(instance = instance, message = message, data = s, coalesce = true))
      }
    )
    case Change -> OnChange(
      toMsg = { s: String ->
        wrap(WidgetEvent(instance = instance, message = message, data = s, coalesce = false))
      }
    )
  }
}

/// Plugin view `t` of placement `instance` as a host view, its handlers
/// producing `WidgetSignal`s wrapped by `toMsg`.  `t` should have passed
/// `treeIssue`; `replyWidget` keeps only views that do.
pub func treeView[Msg](instance: in String, t: in WidgetTree, toMsg: in (WidgetSignal) -> Msg): View[Msg] {
  match t {
    case TreeNode(kind, key, props, handlers, children) -> {
      val hs: List[Handler[Msg]] = newList()
      for h in distinctHandlers(handlers) {
        val hh: Handler[Msg] = hostHandler(instance, h, toMsg)
        hs.add(hh)
      }
      val cs: List[View[Msg]] = newList()
      for c in children {
        val cv: View[Msg] = treeView(instance, c, toMsg)
        cs.add(cv)
      }
      Element(kind = hostKind(kind), key = key, props = hostProps(props), handlers = hs, children = cs)
    }
    case TreeText(s) -> Text(value = s)
    case TreeEmpty -> Empty
  }
}

/// The sentence the error banner shows for a broken placement.
pub func brokenMessage(w: in PluginWidget, reason: in String): String {
  "The widget '" + w.source.widget + "' from plugin '" + w.source.plugin + "' is unavailable: " + reason
}

func hostElement[Msg](
  kind: in WidgetKind,
  key: in String,
  props: in List[Prop],
  handlers: in List[Handler[Msg]],
  children: in List[View[Msg]],
): View[Msg] {
  Element(kind = kind, key = key, props = props, handlers = handlers, children = children)
}

/// Placement `w` as a host view: a column keyed by its instance name holding
/// an error banner and a Retry button when it is broken (keys `status` and
/// `retry`), a loading indicator while it starts (`status`), and the last
/// view the plugin returned (under a column keyed `view`).  Handlers produce
/// `WidgetSignal`s wrapped by `toMsg`.
pub func widgetView[Msg](w: in PluginWidget, toMsg: in (WidgetSignal) -> Msg): View[Msg] {
  val wrap: (WidgetSignal) -> Msg = toMsg
  val kids: List[View[Msg]] = newList()
  val noHandlers: List[Handler[Msg]] = newList()
  match w.status {
    case Broken(reason) -> {
      val tone: List[Prop] = newList()
      tone.add(Prop(name = "tone", value = "error"))
      val msgKids: List[View[Msg]] = newList()
      val msgText: View[Msg] = Text(value = brokenMessage(w, reason))
      msgKids.add(msgText)
      val bannerView: View[Msg] = hostElement(WidgetKind.Banner, "status", tone, noHandlers, msgKids)
      kids.add(bannerView)
      if not isBusy(w) {
        val bprops: List[Prop] = newList()
        bprops.add(Prop(name = "label", value = "Retry"))
        bprops.add(Prop(name = "variant", value = "default"))
        val retryMsg: Msg = wrap(WidgetRetry(instance = w.instance))
        val bhs: List[Handler[Msg]] = newList()
        bhs.add(OnClick(msg = retryMsg))
        val noKids: List[View[Msg]] = newList()
        val retryView: View[Msg] = hostElement(WidgetKind.Button, "retry", bprops, bhs, noKids)
        kids.add(retryView)
      }
    }
    case Starting -> {
      val sprops: List[Prop] = newList()
      sprops.add(Prop(name = "label", value = "Loading " + w.source.widget))
      val noKids: List[View[Msg]] = newList()
      val spinnerView: View[Msg] = hostElement(WidgetKind.Spinner, "status", sprops, noHandlers, noKids)
      kids.add(spinnerView)
    }
    case Ready -> ()
  }
  match w.tree {
    case Some(t) -> {
      val inner: View[Msg] = treeView(w.instance, t, wrap)
      val viewKids: List[View[Msg]] = newList()
      viewKids.add(inner)
      val noProps: List[Prop] = newList()
      val holder: View[Msg] = hostElement(WidgetKind.Column, "view", noProps, noHandlers, viewKids)
      kids.add(holder)
    }
    case None -> ()
  }
  val none: List[Prop] = newList()
  hostElement(WidgetKind.Column, w.instance, none, noHandlers, kids)
}
