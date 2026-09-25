//! Ui.Testing — queries over `View` values for view tests
//! (docs/65-ui-library-sketch.md §12.2).
//! Stability: @experimental — Phase U1 of docs/65.
//!
//! Views are plain values, so a view test renders nothing: it builds the
//! view for a model and asks what it shows, or which message an interaction
//! would produce.
//!
//!   val v = view(model)
//!   assertTrue(Testing.hasText(v, "Credit limit must be between 0 and 1000000"), "error shown")
//!   match Testing.click(v, "Save") {
//!     case Some(m) -> ...   // the message a click produces
//!     case None -> ...      // no enabled "Save" button
//!   }
@runtime_checked
package Ui.Testing

import Std.Core
import Std.String
import Ui.Core.{View, Element, Text, Empty, Handler, WidgetKind, kindName, eventName, fire, lookupProp}

/// All text in `v`, depth first, joined by single spaces.
pub func textOf[Msg](v: in View[Msg]): String {
  val parts: List[String] = newList()
  collectText(v, parts)
  return joinList(" ", parts)
}

pub func collectText[Msg](v: in View[Msg], acc: in List[String]): Unit {
  match v {
    case Text(s) -> if s.length > 0 { acc.add(s) }
    case Empty -> ()
    case Element(_, _, props, _, children) -> {
      match lookupProp(props, "label") {
        case Some(l) -> acc.add(l)
        case None -> ()
      }
      for c in children {
        val cv: View[Msg] = c
        collectText(cv, acc)
      }
    }
  }
}

/// True when `s` occurs in `textOf(v)`.
pub func hasText[Msg](v: in View[Msg], s: in String): Bool {
  return contains(textOf(v), s)
}

/// Every element of `kind` in `v`, depth first.
pub func findAll[Msg](v: in View[Msg], kind: in WidgetKind): List[View[Msg]] {
  val acc: List[View[Msg]] = newList()
  collectKind(v, kindName(kind), acc)
  return acc
}

pub func collectKind[Msg](v: in View[Msg], kind: in String, acc: in List[View[Msg]]): Unit {
  match v {
    case Element(k, _, _, _, children) -> {
      if kindName(k) == kind {
        acc.add(v)
      }
      for c in children {
        val cv: View[Msg] = c
        collectKind(cv, kind, acc)
      }
    }
    case _ -> ()
  }
}

/// The first button labelled `label`, enabled or not.
pub func findButton[Msg](v: in View[Msg], label: in String): Option[View[Msg]] {
  val buttons: List[View[Msg]] = findAll(v, WidgetKind.Button)
  for b in buttons {
    val bv: View[Msg] = b
    match lookupPropOf(bv, "label") {
      case Some(l) -> if l == label { return Some(value = bv) }
      case None -> ()
    }
  }
  return None
}

/// The message a click on the button labelled `label` produces, or `None`
/// when there is no such button or it is disabled or busy.
pub func click[Msg](v: in View[Msg], label: in String): Option[Msg] {
  val found: Option[View[Msg]] = findButton(v, label)
  return match found { case Some(b) -> { val bv: View[Msg] = b; fireOn(bv, "click", "") }; case None -> None }
}

/// The input inside the field labelled `label`.
pub func fieldInput[Msg](v: in View[Msg], label: in String): Option[View[Msg]] {
  val fields: List[View[Msg]] = findAll(v, WidgetKind.Field)
  for f in fields {
    val fv: View[Msg] = f
    match lookupPropOf(fv, "label") {
      case Some(l) -> if l == label {
        return match fv {
          case Element(_, _, _, _, children) -> if children.count > 0 then Some(value = children[0]) else None
          case _ -> None
        }
      }
      case None -> ()
    }
  }
  return None
}

/// The message typing `text` into the field labelled `label` produces, or
/// `None` when there is no such field or its input is read-only.
pub func typeInto[Msg](v: in View[Msg], label: in String, text: in String): Option[Msg] {
  val found: Option[View[Msg]] = fieldInput(v, label)
  return match found { case Some(i) -> { val iv: View[Msg] = i; fireOn(iv, "input", text) }; case None -> None }
}

/// The error messages shown under the field labelled `label`.
pub func fieldErrors[Msg](v: in View[Msg], label: in String): List[String] {
  val acc: List[String] = newList()
  val fields: List[View[Msg]] = findAll(v, WidgetKind.Field)
  for f in fields {
    val fv: View[Msg] = f
    match lookupPropOf(fv, "label") {
      case Some(l) -> if l == label {
        val errs: List[View[Msg]] = findAll(fv, WidgetKind.FieldError)
        for e in errs {
          val ev: View[Msg] = e
          acc.add(textOf(ev))
        }
      }
      case None -> ()
    }
  }
  return acc
}

/// The value of property `name` on element `v`.
pub func lookupPropOf[Msg](v: in View[Msg], name: in String): Option[String] {
  return match v { case Element(_, _, props, _, _) -> lookupProp(props, name); case _ -> None }
}

/// The message element `v`'s handler for event `name` produces with `data`.
pub func fireOn[Msg](v: in View[Msg], name: in String, data: in String): Option[Msg] {
  return match v {
    case Element(_, _, _, handlers, _) -> {
      var acc: Option[Msg] = None
      for h in handlers {
        val hv: Handler[Msg] = h
        if eventName(hv) == name {
          val m: Msg = fire(hv, data)
          acc = Some(value = m)
        }
      }
      acc
    }
    case _ -> None
  }
}
