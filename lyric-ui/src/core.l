//! Ui.Core — the data types shared by every layer of a Lyric UI application
//! (docs/65-ui-library-sketch.md §4, §7).
//! Stability: @experimental — Phase U1 of docs/65.
//!
//! `View[Msg]` is a plain value describing what to show; `Handler[Msg]` says
//! which message an interaction produces; `Step[M, E]` is what `init` and
//! `update` return; `UiEffect[Msg]` is the set of effects the UI runtime
//! interprets itself (navigation, confirmation dialogs, toasts).
//!
//! This package holds data types only.  Screen logic may import it (it needs
//! `Step` and `UiEffect`); only view packages import `Ui.Widgets`, which
//! builds `View` values (docs/65 §5.2).
@runtime_checked
@pure
package Ui.Core

import Std.Core
import Std.Collections
import Std.String
import Std.Parse.{parseOptInt}

// ─── Widgets ──────────────────────────────────────────────────────────────────
/// The closed set of semantic widgets every host implements (docs/65 §7.1).
pub enum WidgetKind {
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
  case DataGrid
  case GridRow
  case GridCell
  case Form
  case Field
  case Dialog
  case Toast
}

/// The protocol name of a widget kind (the string hosts switch on).
pub func kindName(k: in WidgetKind): String {
  return match k {
    case Column -> "column"
    case Row -> "row"
    case Card -> "card"
    case Section -> "section"
    case Spacer -> "spacer"
    case Heading -> "heading"
    case Paragraph -> "paragraph"
    case Label -> "label"
    case Badge -> "badge"
    case TextInput -> "textInput"
    case TextArea -> "textArea"
    case NumberInput -> "numberInput"
    case Checkbox -> "checkbox"
    case Select -> "select"
    case SelectOption -> "option"
    case DateInput -> "dateInput"
    case Button -> "button"
    case Link -> "link"
    case Banner -> "banner"
    case Spinner -> "spinner"
    case FieldError -> "fieldError"
    case Table -> "table"
    case TableRow -> "tableRow"
    case TableCell -> "tableCell"
    case DataGrid -> "dataGrid"
    case GridRow -> "gridRow"
    case GridCell -> "gridCell"
    case Form -> "form"
    case Field -> "field"
    case Dialog -> "dialog"
    case Toast -> "toast"
  }
}

/// A widget property.  Values are strings on the wire; typed builders in
/// `Ui.Widgets` are responsible for formatting them.
pub record Prop {
  name: String
  value: String
}

// ─── Handlers ─────────────────────────────────────────────────────────────────
/// What an interaction with a widget produces.  Handlers never cross the
/// wire: hosts report `(path, event, data)` and the session resolves the
/// handler against its current tree (docs/65 §7.2).
pub union Handler[Msg] {
  case OnClick(msg: Msg)
  case OnInput(toMsg: (String) -> Msg)
  case OnChange(toMsg: (String) -> Msg)
  case OnSubmit(msg: Msg)
  case OnViewport(toMsg: (RowRange) -> Msg)
  case OnSort(toMsg: (String) -> Msg)
}

/// A window of rows: `count` rows from index `first`.  A data grid reports
/// the rows it shows as one (docs/65 §13.6).
pub record RowRange {
  first: Int
  count: Int
}

/// The most rows a host may report in one viewport event.  Larger reports
/// are dropped, so a host cannot make a screen fetch an unbounded window.
pub val maxViewportRows: Int = 1000

/// The row range a viewport event's data (`"first,count"`) names: both
/// non-negative decimal integers, with `count` at most `maxViewportRows`.
@pure
pub func parseRowRange(data: in String): Option[RowRange] {
  val parts = split(data, ",")
  if parts.length != 2 {
    return None
  }
  val first = match parseOptInt(parts[0]) { case Some(n) -> n; case None -> return None }
  val count = match parseOptInt(parts[1]) { case Some(n) -> n; case None -> return None }
  if first < 0 or count < 0 or count > maxViewportRows {
    return None
  }
  return Some(value = RowRange(first = first, count = count))
}

/// The protocol event name a handler answers to.
pub func eventName[Msg](h: in Handler[Msg]): String {
  return match h {
    case OnClick(_) -> "click"
    case OnInput(_) -> "input"
    case OnChange(_) -> "change"
    case OnSubmit(_) -> "submit"
    case OnViewport(_) -> "viewport"
    case OnSort(_) -> "sort"
  }
}

/// Whether `h` takes an event carrying `data`.  A viewport event must
/// name a valid row range (`parseRowRange`); every other event takes any
/// data.  Sessions drop events their handler does not accept.
@pure
pub func accepts[Msg](h: in Handler[Msg], data: in String): Bool {
  return match h {
    case OnViewport(_) -> match parseRowRange(data) { case Some(_) -> true; case None -> false }
    case _ -> true
  }
}

/// The message `h` produces for an event carrying `data`, which `h` must
/// accept (`accepts`).
pub func fire[Msg](h: in Handler[Msg], data: in String): Msg
  requires: accepts(h, data)
{
  return match h {
    case OnClick(m) -> m
    case OnInput(f) -> f(data)
    case OnChange(f) -> f(data)
    case OnSubmit(m) -> m
    case OnViewport(f) -> {
      val r = match parseRowRange(data) { case Some(v) -> v; case None -> RowRange(first = 0, count = 0) }
      f(r)
    }
    case OnSort(f) -> f(data)
  }
}

// ─── Views ────────────────────────────────────────────────────────────────────
/// A description of what to show.  An empty `key` means "unkeyed": children
/// are then reconciled by position (docs/65 §9.1).
///
/// `Lazy` is a subtree whose rendering is skipped when its `fingerprint` is
/// unchanged (docs/65 §13.5, D153): the session renders it once per
/// fingerprint and keeps the result as a `Memo`, which diffing skips while
/// the fingerprint stays the same.  `Memo` is produced by the session, never
/// by views.  Both are transparent: they occupy their subtree's position,
/// and hosts never see them.
pub union View[Msg] {
  case Element(kind: WidgetKind, key: String, props: List[Prop], handlers: List[Handler[Msg]], children: List[View[Msg]])
  case Text(value: String)
  case Empty
  case Lazy(key: String, fingerprint: String, render: () -> View[Msg])
  case Memo(key: String, fingerprint: String, child: View[Msg])
}

/// The view `v` shows: a `Memo`'s subtree, a `Lazy` rendered now, or `v`
/// itself.
pub func viewOf[Msg](v: in View[Msg]): View[Msg] {
  return match v {
    case Memo(_, _, c) -> viewOf(c)
    case Lazy(_, _, r) -> {
      val rendered: View[Msg] = r()
      viewOf(rendered)
    }
    case _ -> v
  }
}

/// The value of property `name` on `v`, if `v` is an element carrying it.
pub func propOf[Msg](v: in View[Msg], name: in String): Option[String] {
  return match viewOf(v) { case Element(_, _, props, _, _) -> lookupProp(props, name); case _ -> None }
}

/// The value of property `name` in `props`.
pub func lookupProp(props: in List[Prop], name: in String): Option[String] {
  for p in props {
    if p.name == name {
      return Some(value = p.value)
    }
  }
  return None
}

/// The children of `v` (empty for text and empty views).
pub func childrenOf[Msg](v: in View[Msg]): List[View[Msg]] {
  return match viewOf(v) {
    case Element(_, _, _, _, cs) -> cs
    case _ -> {
      val none: List[View[Msg]] = newList()
      none
    }
  }
}

/// `v` with every handler's message wrapped by `f`.  This is how a parent
/// embeds a child component's view (docs/65 §6.2).
pub func mapView[A, B](v: in View[A], f: in (A) -> B): View[B] {
  return match v {
    case Element(kind, key, props, handlers, children) -> {
      val hs: List[Handler[B]] = newList()
      for h in handlers {
        hs.add(mapHandler(h, f))
      }
      val cs: List[View[B]] = newList()
      for c in children {
        cs.add(mapView(c, f))
      }
      Element(kind = kind, key = key, props = props, handlers = hs, children = cs)
    }
    case Text(s) -> Text(value = s)
    case Empty -> Empty
    case Lazy(key, fingerprint, r) -> Lazy(
      key = key,
      fingerprint = fingerprint,
      render = { -> val rendered: View[A] = r(); mapView(rendered, f) }
    )
    case Memo(key, fingerprint, c) -> Memo(key = key, fingerprint = fingerprint, child = mapView(c, f))
  }
}

/// `h` with its message wrapped by `f`.
pub func mapHandler[A, B](h: in Handler[A], f: in (A) -> B): Handler[B] {
  return match h {
    case OnClick(m) -> {
      val wrapped: B = f(m)
      OnClick(msg = wrapped)
    }
    case OnInput(g) -> OnInput(toMsg = compose(g, f))
    case OnChange(g) -> OnChange(toMsg = compose(g, f))
    case OnSubmit(m) -> {
      val wrapped: B = f(m)
      OnSubmit(msg = wrapped)
    }
    case OnViewport(g) -> OnViewport(toMsg = { r: RowRange -> f(g(r)) })
    case OnSort(g) -> OnSort(toMsg = compose(g, f))
  }
}

/// `{ s -> outer(inner(s)) }`.
pub func compose[A, B](inner: in (String) -> A, outer: in (A) -> B): (String) -> B {
  return { s: String -> outer(inner(s)) }
}

// ─── Steps ────────────────────────────────────────────────────────────────────
/// The result of `init` and `update`: the next model and the effects the
/// screen asks for, as data (docs/65 §4.1).
pub record Step[M, E] {
  model: M
  effects: List[E]
}

/// A step with no effects.
pub func stay[M, E](m: in M): Step[M, E] {
  val none: List[E] = newList()
  return Step(model = m, effects = none)
}

/// A step with exactly one effect.
pub func step1[M, E](m: in M, e: in E): Step[M, E] {
  val es: List[E] = newList()
  es.add(e)
  return Step(model = m, effects = es)
}

/// A step with the given effects.
pub func stepAll[M, E](m: in M, es: in List[E]): Step[M, E] {
  return Step(model = m, effects = es)
}

// ─── Effects the runtime interprets ───────────────────────────────────────────
/// The severity of a toast notification.
pub enum ToastLevel {
  case Info
  case Success
  case Warning
  case Error
}

/// Effects the UI runtime interprets itself.  A screen's own `Effect` union
/// embeds these (typically as `case Ui(effect: UiEffect[Msg])`) and tells the
/// runtime how to find them through `Program.uiEffect` (docs/65 §6.3).
pub union UiEffect[Msg] {
  case Navigate(url: String)
  case Back
  case Confirm(question: String, onYes: Msg)
  case Notify(message: String, level: ToastLevel)
}

/// The protocol name of a toast level.
pub func toastLevelName(l: in ToastLevel): String {
  return match l { case Info -> "info"; case Success -> "success"; case Warning -> "warning"; case Error -> "error" }
}
