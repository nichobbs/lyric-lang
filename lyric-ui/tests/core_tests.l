//! tests/core_tests.l — Ui.Core handlers and view mapping, Ui.Testing
//! queries, and Ui.Forms schema rendering.
@test_module
package Ui.CoreTests

import Std.Core
import Std.Testing
import Forms
import Forms.{FieldError, FormSchema, FieldSpec, InputKind}
import Ui.Core.{View, Handler, OnClick, OnInput, eventName, fire, mapView}
import Ui.Forms.{formFields}
import Ui.Testing as UiTest
import Ui.Widgets.{button, column, field, textInput, inputOpts, primaryButton}

union Child {
  case Pressed
  case Typed(s: String)
}

union Parent {
  case FromChild(msg: Child)
  case Edited(field: String, value: String)
}

func childView(): View[Child] {
  val cs: List[View[Child]] = newList()
  val press: View[Child] = button[Child]("Press", Pressed)
  val noErrors: List[String] = newList()
  val input: View[Child] = textInput[Child]("text", "", { s: String -> Typed(s = s) }, inputOpts())
  val name: View[Child] = field("Name", noErrors, input)
  cs.add(press)
  cs.add(name)
  return column(cs)
}

test "handlers fire their messages" {
  val h: Handler[Child] = OnInput(toMsg = { s: String -> Typed(s = s) })
  assertEqual(eventName(h), "input", "event name")
  match fire(h, "abc") {
    case Typed(s) -> assertEqual(s, "abc", "payload")
    case _ -> assertTrue(false, "expected Typed")
  }
}

test "mapView wraps every handler of a child view" {
  val wrap: (Child) -> Parent = { c: Child -> FromChild(msg = c) }
  val child: View[Child] = childView()
  val v: View[Parent] = mapView(child, wrap)
  match UiTest.click(v, "Press") {
    case Some(FromChild(Pressed)) -> assertTrue(true, "click wrapped")
    case _ -> assertTrue(false, "expected FromChild(Pressed)")
  }
  match UiTest.typeInto(v, "Name", "Ann") {
    case Some(FromChild(Typed(s))) -> assertEqual(s, "Ann", "input wrapped")
    case _ -> assertTrue(false, "expected FromChild(Typed)")
  }
}

test "busy and disabled buttons produce no click" {
  val busy: View[Child] = primaryButton[Child]("Save", Pressed, true)
  assertTrue(UiTest.findButton(busy, "Save").isSome, "button exists")
  match UiTest.click(busy, "Save") {
    case Some(_) -> assertTrue(false, "busy button must not click")
    case None -> assertTrue(true, "no click")
  }
}

func schema(): FormSchema {
  val fs: List[FieldSpec] = newList()
  fs.add(Forms.required(Forms.fieldSpec("name", "Name", InputKind.Text)))
  fs.add(Forms.bounded(Forms.fieldSpec("limit", "Credit limit", InputKind.Number), 0, 100))
  fs.add(Forms.readonly(Forms.fieldSpec("id", "Id", InputKind.Text)))
  return Forms.schema(fs)
}

func draftValue(name: in String): String {
  if name == "name" {
    return "Acme"
  }
  if name == "limit" {
    return "500"
  }
  return "C-1"
}

test "Ui.Forms renders a schema with values, bounds and errors" {
  val errs: List[FieldError] = newList()
  errs.add(Forms.OutOfRange(field = Forms.fieldPath("limit"), min = 0, max = 100))
  val onEdit: (String, String) -> Parent = { f: String, v: String -> Edited(field = f, value = v) }
  val valueOf: (String) -> String = draftValue
  val fields: List[View[Parent]] = formFields(schema(), valueOf, errs, onEdit)
  val v: View[Parent] = column(fields)
  assertEqualInt(fields.count, 3, "three fields")
  val limitErrors = UiTest.fieldErrors(v, "Credit limit")
  assertEqualInt(limitErrors.count, 1, "one limit error")
  assertEqual(limitErrors[0], "Credit limit must be between 0 and 100", "message")
  match UiTest.fieldInput(v, "Credit limit") {
    case Some(found) -> {
      val i: View[Parent] = found
      assertTrue(UiTest.lookupPropOf(i, "max") == Some(value = "100"), "max bound")
      assertTrue(UiTest.lookupPropOf(i, "value") == Some(value = "500"), "value")
    }
    case None -> assertTrue(false, "expected the limit input")
  }
  match UiTest.typeInto(v, "Name", "Acme Pty") {
    case Some(Edited(f, value)) -> {
      assertEqual(f, "name", "field name")
      assertEqual(value, "Acme Pty", "value")
    }
    case _ -> assertTrue(false, "expected Edited")
  }
  match UiTest.typeInto(v, "Id", "x") {
    case Some(_) -> assertTrue(false, "read-only input must not produce input messages")
    case None -> assertTrue(true, "read-only")
  }
}
