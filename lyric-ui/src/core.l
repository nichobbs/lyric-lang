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
package Ui.Core

import Std.Core

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
}

/// The protocol event name a handler answers to.
pub func eventName[Msg](h: in Handler[Msg]): String {
  return match h {
    case OnClick(_) -> "click"
    case OnInput(_) -> "input"
    case OnChange(_) -> "change"
    case OnSubmit(_) -> "submit"
  }
}

/// The message `h` produces for an event carrying `data`.
pub func fire[Msg](h: in Handler[Msg], data: in String): Msg {
  return match h {
    case OnClick(m) -> m
    case OnInput(f) -> f(data)
    case OnChange(f) -> f(data)
    case OnSubmit(m) -> m
  }
}

// ─── Views ────────────────────────────────────────────────────────────────────
/// A description of what to show.  An empty `key` means "unkeyed": children
/// are then reconciled by position (docs/65 §9.1).
pub union View[Msg] {
  case Element(kind: WidgetKind, key: String, props: List[Prop], handlers: List[Handler[Msg]], children: List[View[Msg]])
  case Text(value: String)
  case Empty
}

/// The value of property `name` on `v`, if `v` is an element carrying it.
pub func propOf[Msg](v: in View[Msg], name: in String): Option[String] {
  return match v { case Element(_, _, props, _, _) -> lookupProp(props, name); case _ -> None }
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
  return match v { case Element(_, _, _, _, cs) -> cs; case _ -> { val none: List[View[Msg]] = newList(); none } }
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
