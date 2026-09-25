//! Ui.Widgets — typed builders for the semantic widget set
//! (docs/65-ui-library-sketch.md §7.1).
//! Stability: @experimental — Phase U1 of docs/65.
//!
//! Only view packages import this module (docs/65 §5.2).  Every builder
//! returns a `View[Msg]`; properties are formatted to strings here so the
//! diff and the protocol stay generic.
@runtime_checked
package Ui.Widgets

import Std.Core
import Ui.Core.{View, Element, Text, Empty, Handler, OnClick, OnInput, OnChange, OnSubmit, Prop, WidgetKind}

// ─── Low-level constructors ───────────────────────────────────────────────────
/// A general element.  Prefer the typed builders below.
pub func element[Msg](
  kind: in WidgetKind,
  props: in List[Prop],
  handlers: in List[Handler[Msg]],
  children: in List[View[Msg]],
): View[Msg] {
  return Element(kind = kind, key = "", props = props, handlers = handlers, children = children)
}

/// `v` with key `key`, for keyed reconciliation of dynamic lists.  Text and
/// empty views are returned unchanged.
pub func keyed[Msg](key: in String, v: in View[Msg]): View[Msg] {
  return match v {
    case Element(kind, _, props, handlers, children) -> Element(
      kind = kind,
      key = key,
      props = props,
      handlers = handlers,
      children = children
    )
    case _ -> v
  }
}

/// A text node.
pub func text[Msg](s: in String): View[Msg] {
  return Text(value = s)
}

/// Nothing.
pub func nothing[Msg](): View[Msg] {
  return Empty
}

/// `v` when `cond` holds, otherwise nothing.
pub func showIf[Msg](cond: in Bool, v: in View[Msg]): View[Msg] {
  if cond {
    return v
  }
  return Empty
}

pub func prop(name: in String, value: in String): Prop {
  return Prop(name = name, value = value)
}

pub func noProps(): List[Prop] {
  val ps: List[Prop] = newList()
  return ps
}

pub func textChild[Msg](t: in View[Msg]): List[View[Msg]] {
  val cs: List[View[Msg]] = newList()
  cs.add(t)
  return cs
}

pub func boolText(b: in Bool): String {
  if b {
    return "true"
  }
  return "false"
}

// ─── Layout ───────────────────────────────────────────────────────────────────
/// Children stacked vertically.
pub func column[Msg](children: in List[View[Msg]]): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  return element(WidgetKind.Column, noProps(), noHs, children)
}

/// Children laid out horizontally.
pub func row[Msg](children: in List[View[Msg]]): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  return element(WidgetKind.Row, noProps(), noHs, children)
}

/// A titled surface grouping related content.
pub func card[Msg](title: in String, children: in List[View[Msg]]): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val ps = noProps()
  ps.add(prop("title", title))
  return element(WidgetKind.Card, ps, noHs, children)
}

/// A titled group within a form or card.
pub func section[Msg](title: in String, children: in List[View[Msg]]): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val ps = noProps()
  ps.add(prop("title", title))
  return element(WidgetKind.Section, ps, noHs, children)
}

// ─── Text ─────────────────────────────────────────────────────────────────────
/// A heading of `level` 1 (page) to 3 (subsection).
pub func heading[Msg](level: in Int, s: in String): View[Msg]
  requires: level >= 1 and level <= 3
{
  val noHs: List[Handler[Msg]] = newList()
  val t: View[Msg] = Text(value = s)
  val kids: List[View[Msg]] = textChild(t)
  val ps = noProps()
  ps.add(prop("level", level.toString()))
  return element(WidgetKind.Heading, ps, noHs, kids)
}

/// A paragraph of body text.
pub func paragraph[Msg](s: in String): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val t: View[Msg] = Text(value = s)
  val kids: List[View[Msg]] = textChild(t)
  return element(WidgetKind.Paragraph, noProps(), noHs, kids)
}

/// A small status badge.  `tone` is one of `neutral`, `info`, `success`,
/// `warning`, `error`.
pub func badge[Msg](s: in String, tone: in String): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val t: View[Msg] = Text(value = s)
  val kids: List[View[Msg]] = textChild(t)
  val ps = noProps()
  ps.add(prop("tone", tone))
  return element(WidgetKind.Badge, ps, noHs, kids)
}

// ─── Feedback ─────────────────────────────────────────────────────────────────
/// A full-width message.  `tone` as for `badge`.
pub func banner[Msg](tone: in String, s: in String): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val t: View[Msg] = Text(value = s)
  val kids: List[View[Msg]] = textChild(t)
  val ps = noProps()
  ps.add(prop("tone", tone))
  return element(WidgetKind.Banner, ps, noHs, kids)
}

/// A loading indicator with an accessible label.
pub func spinner[Msg](label: in String): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val noCs: List[View[Msg]] = newList()
  val ps = noProps()
  ps.add(prop("label", label))
  return element(WidgetKind.Spinner, ps, noHs, noCs)
}

// ─── Actions ──────────────────────────────────────────────────────────────────
/// Button options.  `variant` is `default`, `primary` or `danger`; a `busy`
/// button shows progress and ignores clicks.
pub record ButtonOpts {
  variant: String
  disabled: Bool
  busy: Bool
}

/// The default button options.
pub func buttonOpts(): ButtonOpts {
  return ButtonOpts(variant = "default", disabled = false, busy = false)
}

/// A button producing `onClick` when pressed.
pub func button[Msg](label: in String, onClick: in Msg): View[Msg] {
  return buttonWith(label, onClick, buttonOpts())
}

/// A primary (call-to-action) button.
pub func primaryButton[Msg](label: in String, onClick: in Msg, busy: in Bool): View[Msg] {
  return buttonWith(label, onClick, ButtonOpts(variant = "primary", disabled = false, busy = busy))
}

/// A button with explicit options.
pub func buttonWith[Msg](label: in String, onClick: in Msg, opts: in ButtonOpts): View[Msg] {
  val noCs: List[View[Msg]] = newList()
  val ps = noProps()
  ps.add(prop("label", label))
  ps.add(prop("variant", opts.variant))
  if opts.disabled {
    ps.add(prop("disabled", "true"))
  }
  if opts.busy {
    ps.add(prop("busy", "true"))
  }
  val hs: List[Handler[Msg]] = newList()
  if not opts.disabled and not opts.busy {
    hs.add(OnClick(msg = onClick))
  }
  return element(WidgetKind.Button, ps, hs, noCs)
}

/// A navigation link to an application URL.  Hosts navigate within the
/// application without a page load.
pub func link[Msg](label: in String, url: in String): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val t: View[Msg] = Text(value = label)
  val kids: List[View[Msg]] = textChild(t)
  val ps = noProps()
  ps.add(prop("href", url))
  return element(WidgetKind.Link, ps, noHs, kids)
}

// ─── Forms and inputs ─────────────────────────────────────────────────────────
/// A form; pressing Enter in a text input or a submit button produces
/// `onSubmit`.
pub func form[Msg](onSubmit: in Msg, children: in List[View[Msg]]): View[Msg] {
  val hs: List[Handler[Msg]] = newList()
  hs.add(OnSubmit(msg = onSubmit))
  return element(WidgetKind.Form, noProps(), hs, children)
}

/// A labelled field wrapping one input, with its error messages.  Hosts
/// associate the label and errors with the input for accessibility.
pub func field[Msg](label: in String, errors: in List[String], input: in View[Msg]): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val ps = noProps()
  ps.add(prop("label", label))
  if errors.count > 0 {
    ps.add(prop("invalid", "true"))
  }
  val cs: List[View[Msg]] = newList()
  cs.add(input)
  for e in errors {
    val t: View[Msg] = Text(value = e)
    val kids: List[View[Msg]] = textChild(t)
    val err: View[Msg] = element(WidgetKind.FieldError, noProps(), noHs, kids)
    cs.add(err)
  }
  return element(WidgetKind.Field, ps, noHs, cs)
}

/// Input options shared by the text-like inputs.
pub record InputOpts {
  placeholder: String
  required: Bool
  readonly: Bool
  maxLength: Int
}

/// The default input options (no placeholder, optional, editable,
/// unlimited length).
pub func inputOpts(): InputOpts {
  return InputOpts(placeholder = "", required = false, readonly = false, maxLength = 0)
}

pub func inputProps(value: in String, opts: in InputOpts): List[Prop] {
  val ps = noProps()
  ps.add(prop("value", value))
  if opts.placeholder.length > 0 {
    ps.add(prop("placeholder", opts.placeholder))
  }
  if opts.required {
    ps.add(prop("required", "true"))
  }
  if opts.readonly {
    ps.add(prop("readonly", "true"))
  }
  if opts.maxLength > 0 {
    ps.add(prop("maxLength", opts.maxLength.toString()))
  }
  return ps
}

pub func inputHandlers[Msg](onInput: in (String) -> Msg, opts: in InputOpts): List[Handler[Msg]] {
  val hs: List[Handler[Msg]] = newList()
  if not opts.readonly {
    hs.add(OnInput(toMsg = onInput))
  }
  return hs
}

/// A single-line text input.  `kind` is `text`, `email`, `password`, `tel`
/// or `url` (a hint for the host's keyboard and autofill).
pub func textInput[Msg](kind: in String, value: in String, onInput: in (String) -> Msg, opts: in InputOpts): View[Msg] {
  val noCs: List[View[Msg]] = newList()
  val ps = inputProps(value, opts)
  ps.add(prop("type", kind))
  val hs: List[Handler[Msg]] = inputHandlers(onInput, opts)
  return element(WidgetKind.TextInput, ps, hs, noCs)
}

/// A multi-line text input.
pub func textArea[Msg](value: in String, onInput: in (String) -> Msg, opts: in InputOpts): View[Msg] {
  val noCs: List[View[Msg]] = newList()
  val hs: List[Handler[Msg]] = inputHandlers(onInput, opts)
  return element(WidgetKind.TextArea, inputProps(value, opts), hs, noCs)
}

/// Inclusive advisory bounds for a numeric input.
pub record NumberBounds {
  min: Long
  max: Long
}

/// A numeric input.  `value` is draft text: the input does not reject
/// non-numeric text, validation does.  Bounds are advisory for the host.
pub func numberInput[Msg](
  value: in String,
  onInput: in (String) -> Msg,
  opts: in InputOpts,
  bounds: in Option[NumberBounds],
): View[Msg] {
  val noCs: List[View[Msg]] = newList()
  val ps = inputProps(value, opts)
  match bounds {
    case Some(b) -> {
      ps.add(prop("min", b.min.toString()))
      ps.add(prop("max", b.max.toString()))
    }
    case None -> ()
  }
  val hs: List[Handler[Msg]] = inputHandlers(onInput, opts)
  return element(WidgetKind.NumberInput, ps, hs, noCs)
}

/// A checkbox.  The change handler receives `"true"` or `"false"`.
pub func checkbox[Msg](label: in String, checked: in Bool, onChange: in (String) -> Msg): View[Msg] {
  val noCs: List[View[Msg]] = newList()
  val ps = noProps()
  ps.add(prop("label", label))
  ps.add(prop("checked", boolText(checked)))
  val hs: List[Handler[Msg]] = newList()
  hs.add(OnChange(toMsg = onChange))
  return element(WidgetKind.Checkbox, ps, hs, noCs)
}

/// One option of a select: a value and its display label.
pub record SelectChoice {
  value: String
  label: String
}

/// A drop-down choice.  The change handler receives the chosen value.
pub func select[Msg](value: in String, choices: in List[SelectChoice], onChange: in (String) -> Msg): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val ps = noProps()
  ps.add(prop("value", value))
  val cs: List[View[Msg]] = newList()
  for c in choices {
    val ops = noProps()
    ops.add(prop("value", c.value))
    val label: View[Msg] = Text(value = c.label)
    val optionKids: List[View[Msg]] = textChild(label)
    val option: View[Msg] = element(WidgetKind.SelectOption, ops, noHs, optionKids)
    cs.add(keyed(c.value, option))
  }
  val hs: List[Handler[Msg]] = newList()
  hs.add(OnChange(toMsg = onChange))
  return element(WidgetKind.Select, ps, hs, cs)
}

// ─── Tables ───────────────────────────────────────────────────────────────────
/// A table with a header row.  Each row should be keyed (see `keyed`) so
/// that inserts and reorders patch only the affected rows.
pub func table[Msg](headers: in List[String], rows: in List[View[Msg]]): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val hcells: List[View[Msg]] = newList()
  for h in headers {
    val hp = noProps()
    hp.add(prop("header", "true"))
    val t: View[Msg] = Text(value = h)
    val kids: List[View[Msg]] = textChild(t)
    val cell: View[Msg] = element(WidgetKind.TableCell, hp, noHs, kids)
    hcells.add(cell)
  }
  val cs: List[View[Msg]] = newList()
  val headerRow: View[Msg] = element(WidgetKind.TableRow, noProps(), noHs, hcells)
  cs.add(keyed("__header", headerRow))
  for r in rows {
    cs.add(r)
  }
  return element(WidgetKind.Table, noProps(), noHs, cs)
}

/// A table row of cells.  `onClick`, when present, makes the row
/// activatable (keyboard and pointer).
pub func tableRow[Msg](cells: in List[View[Msg]], onClick: in Option[Msg]): View[Msg] {
  val noHs: List[Handler[Msg]] = newList()
  val cs: List[View[Msg]] = newList()
  for c in cells {
    val cellKids: List[View[Msg]] = textChild(c)
    val cell: View[Msg] = element(WidgetKind.TableCell, noProps(), noHs, cellKids)
    cs.add(cell)
  }
  val hs: List[Handler[Msg]] = newList()
  match onClick {
    case Some(m) -> hs.add(OnClick(msg = m))
    case None -> ()
  }
  return element(WidgetKind.TableRow, noProps(), hs, cs)
}
