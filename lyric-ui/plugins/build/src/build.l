//! Ui.Plugins.Build — builders for a widget plugin's view (`WidgetTree`).
//! Stability: @experimental.
//!
//! The same builders as `Ui.Widgets`, with the same properties, so a tree a
//! plugin builds renders exactly as the host's own widgets do.  Where a
//! `Ui.Widgets` builder takes a message or a function producing one, these
//! take the message string the host sends back in a `WidgetMessage`; the
//! text of an input or change event arrives as that message's `data`.
@runtime_checked
@pure
package Ui.Plugins.Build

import Std.Core
import Std.Collections
import Ui.Plugins.{WidgetTree, TreeNode, TreeText, TreeEmpty, NodeKind, NodeEvent, NodeProp, NodeHandler}

// ─── Low-level constructors ───────────────────────────────────────────────────
/// A general node.  Prefer the typed builders below.
pub func node(
  kind: in NodeKind, props: in List[NodeProp], handlers: in List[NodeHandler], children: in List[WidgetTree]
): WidgetTree {
  TreeNode(kind = kind, key = "", props = props, handlers = handlers, children = children)
}

/// `t` with key `key`, for keyed reconciliation of dynamic lists.  Text and
/// empty trees are returned unchanged.
pub func keyed(key: in String, t: in WidgetTree): WidgetTree {
  match t {
    case TreeNode(kind, _, props, handlers, children) -> TreeNode(
      kind = kind,
      key = key,
      props = props,
      handlers = handlers,
      children = children
    )
    case _ -> t
  }
}

/// A text node.
pub func text(s: in String): WidgetTree {
  TreeText(text = s)
}

/// Nothing.
pub func nothing(): WidgetTree {
  TreeEmpty
}

/// `t` when `cond` holds, otherwise nothing.
pub func showIf(cond: in Bool, t: in WidgetTree): WidgetTree {
  if cond then t else TreeEmpty
}

/// A property.
pub func prop(name: in String, value: in String): NodeProp {
  NodeProp(name = name, value = value)
}

/// A handler producing `message` for `event`.
pub func on(event: in NodeEvent, message: in String): NodeHandler {
  NodeHandler(event = event, message = message)
}

func noProps(): List[NodeProp] {
  newList()
}

func noHandlers(): List[NodeHandler] {
  newList()
}

func noChildren(): List[WidgetTree] {
  newList()
}

func textChildren(s: in String): List[WidgetTree] {
  val cs: List[WidgetTree] = newList()
  cs.add(TreeText(text = s))
  cs
}

func boolText(b: in Bool): String {
  if b then "true" else "false"
}

// ─── Layout ───────────────────────────────────────────────────────────────────
/// Children stacked vertically.
pub func column(children: in List[WidgetTree]): WidgetTree {
  node(NodeKind.Column, noProps(), noHandlers(), children)
}

/// Children laid out horizontally.
pub func row(children: in List[WidgetTree]): WidgetTree {
  node(NodeKind.Row, noProps(), noHandlers(), children)
}

/// A titled surface grouping related content.
pub func card(title: in String, children: in List[WidgetTree]): WidgetTree {
  val ps = noProps()
  ps.add(prop("title", title))
  node(NodeKind.Card, ps, noHandlers(), children)
}

/// A titled group.
pub func section(title: in String, children: in List[WidgetTree]): WidgetTree {
  val ps = noProps()
  ps.add(prop("title", title))
  node(NodeKind.Section, ps, noHandlers(), children)
}

// ─── Text ─────────────────────────────────────────────────────────────────────
/// A heading of `level` 1 (page) to 3 (subsection).
pub func heading(level: in Int, s: in String): WidgetTree
  requires: level >= 1 and level <= 3
{
  val ps = noProps()
  ps.add(prop("level", level.toString()))
  node(NodeKind.Heading, ps, noHandlers(), textChildren(s))
}

/// A paragraph of body text.
pub func paragraph(s: in String): WidgetTree {
  node(NodeKind.Paragraph, noProps(), noHandlers(), textChildren(s))
}

/// A small status badge.  `tone` is one of `neutral`, `info`, `success`,
/// `warning`, `error`.
pub func badge(s: in String, tone: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("tone", tone))
  node(NodeKind.Badge, ps, noHandlers(), textChildren(s))
}

// ─── Feedback ─────────────────────────────────────────────────────────────────
/// A full-width message.  `tone` as for `badge`.
pub func banner(tone: in String, s: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("tone", tone))
  node(NodeKind.Banner, ps, noHandlers(), textChildren(s))
}

/// A loading indicator with an accessible label.
pub func spinner(label: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("label", label))
  node(NodeKind.Spinner, ps, noHandlers(), noChildren())
}

// ─── Actions ──────────────────────────────────────────────────────────────────
/// A button sending `message` when pressed.
pub func button(label: in String, message: in String): WidgetTree {
  buttonWith(label, message, "default", false)
}

/// A primary (call-to-action) button.
pub func primaryButton(label: in String, message: in String): WidgetTree {
  buttonWith(label, message, "primary", false)
}

/// A button with a `variant` (`default`, `primary` or `danger`); a disabled
/// button sends nothing.
pub func buttonWith(label: in String, message: in String, variant: in String, disabled: in Bool): WidgetTree {
  val ps = noProps()
  ps.add(prop("label", label))
  ps.add(prop("variant", variant))
  val hs = noHandlers()
  if disabled {
    ps.add(prop("disabled", "true"))
  } else {
    hs.add(on(NodeEvent.Click, message))
  }
  node(NodeKind.Button, ps, hs, noChildren())
}

/// A navigation link.  A host follows only an application path (`/...`) or
/// an `http`/`https` URL and drops any other `href`.
pub func link(label: in String, url: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("href", url))
  node(NodeKind.Link, ps, noHandlers(), textChildren(label))
}

// ─── Forms and inputs ─────────────────────────────────────────────────────────
/// A form; pressing Enter in a text input or a submit button sends `message`.
pub func form(message: in String, children: in List[WidgetTree]): WidgetTree {
  val hs = noHandlers()
  hs.add(on(NodeEvent.Submit, message))
  node(NodeKind.Form, noProps(), hs, children)
}

/// A labelled field wrapping one input, with its error messages.
pub func field(label: in String, errors: in List[String], input: in WidgetTree): WidgetTree {
  val ps = noProps()
  ps.add(prop("label", label))
  if errors.count > 0 {
    ps.add(prop("invalid", "true"))
  }
  val cs: List[WidgetTree] = newList()
  cs.add(input)
  for e in errors {
    cs.add(node(NodeKind.FieldError, noProps(), noHandlers(), textChildren(e)))
  }
  node(NodeKind.Field, ps, noHandlers(), cs)
}

/// A single-line text input showing `value`; each edit sends `message` with
/// the input's text as data.  `kind` is `text`, `email`, `password`, `tel`
/// or `url`.
pub func textInput(kind: in String, value: in String, message: in String, placeholder: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("value", value))
  if placeholder.length > 0 {
    ps.add(prop("placeholder", placeholder))
  }
  ps.add(prop("type", kind))
  val hs = noHandlers()
  hs.add(on(NodeEvent.Input, message))
  node(NodeKind.TextInput, ps, hs, noChildren())
}

/// A multi-line text input; edits as for `textInput`.
pub func textArea(value: in String, message: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("value", value))
  val hs = noHandlers()
  hs.add(on(NodeEvent.Input, message))
  node(NodeKind.TextArea, ps, hs, noChildren())
}

/// A code editor: a multi-line text input drawn in a monospace font with a
/// line-number gutter and highlighting for `language` (`lyric` and `json`; any
/// other name is plain text); edits as for `textInput`.
pub func codeEditor(value: in String, message: in String, language: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("value", value))
  ps.add(prop("variant", "code"))
  if language.length > 0 {
    ps.add(prop("language", language))
  }
  val hs = noHandlers()
  hs.add(on(NodeEvent.Input, message))
  node(NodeKind.TextArea, ps, hs, noChildren())
}

/// A numeric input with inclusive advisory bounds; edits as for `textInput`.
pub func numberInput(value: in String, message: in String, min: in Long, max: in Long): WidgetTree
  requires: min <= max
{
  val ps = noProps()
  ps.add(prop("value", value))
  ps.add(prop("min", min.toString()))
  ps.add(prop("max", max.toString()))
  val hs = noHandlers()
  hs.add(on(NodeEvent.Input, message))
  node(NodeKind.NumberInput, ps, hs, noChildren())
}

/// A checkbox; a change sends `message` with data `"true"` or `"false"`.
pub func checkbox(label: in String, checked: in Bool, message: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("label", label))
  ps.add(prop("checked", boolText(checked)))
  val hs = noHandlers()
  hs.add(on(NodeEvent.Change, message))
  node(NodeKind.Checkbox, ps, hs, noChildren())
}

/// One choice of a select: a value and its display label.
pub record Choice {
  value: String
  label: String
}

/// A drop-down choice; a change sends `message` with the chosen value.
pub func select(value: in String, choices: in List[Choice], message: in String): WidgetTree {
  val ps = noProps()
  ps.add(prop("value", value))
  val cs: List[WidgetTree] = newList()
  for c in choices {
    val ops = noProps()
    ops.add(prop("value", c.value))
    cs.add(keyed(c.value, node(NodeKind.SelectOption, ops, noHandlers(), textChildren(c.label))))
  }
  val hs = noHandlers()
  hs.add(on(NodeEvent.Change, message))
  node(NodeKind.Select, ps, hs, cs)
}

// ─── Tables ───────────────────────────────────────────────────────────────────
/// A table with a header row.  Key each row (see `keyed`).
pub func table(headers: in List[String], rows: in List[WidgetTree]): WidgetTree {
  val hcells: List[WidgetTree] = newList()
  for h in headers {
    val hp = noProps()
    hp.add(prop("header", "true"))
    hcells.add(node(NodeKind.TableCell, hp, noHandlers(), textChildren(h)))
  }
  val cs: List[WidgetTree] = newList()
  cs.add(keyed("__header", node(NodeKind.TableRow, noProps(), noHandlers(), hcells)))
  for r in rows {
    cs.add(r)
  }
  node(NodeKind.Table, noProps(), noHandlers(), cs)
}

/// A table row of cells; a click sends `message` when it is not empty.
pub func tableRow(cells: in List[WidgetTree], message: in String): WidgetTree {
  val cs: List[WidgetTree] = newList()
  for c in cells {
    val kids: List[WidgetTree] = newList()
    kids.add(c)
    cs.add(node(NodeKind.TableCell, noProps(), noHandlers(), kids))
  }
  val hs = noHandlers()
  if message.length > 0 {
    hs.add(on(NodeEvent.Click, message))
  }
  node(NodeKind.TableRow, noProps(), hs, cs)
}
