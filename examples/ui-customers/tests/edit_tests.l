//! tests/edit_tests.l — the edit-customer screen, tested with no UI host:
//! logic through `update`, view through `Ui.Testing` queries, and the two
//! together through a `Ui.Session` driven by host-shaped events.
@test_module
package Customers.EditTests

import Std.Core
import Std.Testing
import Forms
import Ui.Core.{View, Step, UiEffect, Navigate, Confirm, Notify}
import Ui.Testing as UiTest
import Ui.Session
import Ui.Session.{Program, NavigateTo, ShowToast}
import Customers.Domain.{Customer, CustomerId, CreditLimit, CustomerField, Tier, keyAccountMessage}
import Customers.Edit.Logic
import Customers.Edit.Logic.{Model, Msg, Effect, Loaded, FieldEdited, SaveClicked, Saved, CancelClicked, DiscardConfirmed, LoadCustomer, SaveCustomer, Ui, Status}
import Customers.Edit.View

func sample(): Customer {
  return Customer(
    id = CustomerId.from(7),
    name = "Acme",
    email = "ap@acme.test",
    creditLimit = CreditLimit.from(5000),
    tier = Tier.Standard,
    notes = None
  )
}

func loaded(): Model {
  return Logic.update(Logic.init(CustomerId.from(7)).model, Loaded(outcome = Ok(value = sample()))).model
}

func edit(m: in Model, f: in CustomerField, v: in String): Model {
  return Logic.update(m, FieldEdited(field = f, value = v)).model
}

func isUi(e: in Effect): Bool {
  return match e { case Ui(_) -> true; case _ -> false }
}

// ─── Logic ────────────────────────────────────────────────────────────────────
test "init asks for the customer and shows a spinner" {
  val s = Logic.init(CustomerId.from(7))
  assertEqualInt(s.effects.count, 1, "one effect")
  match s.effects[0] {
    case LoadCustomer(id) -> assertTrue(id.toLong() == 7, "loads customer 7")
    case _ -> assertTrue(false, "expected LoadCustomer")
  }
  assertTrue(UiTest.hasText(View.view(s.model), "Loading customer"), "spinner label")
}

test "loading fills the draft from the customer" {
  val m = loaded()
  assertEqual(m.draft.name, "Acme", "name")
  assertEqual(m.draft.creditLimit, "5000", "limit as text")
  assertFalse(m.dirty, "not dirty")
}

test "an out-of-range credit limit blocks save and reports the field" {
  val m = edit(loaded(), CustomerField.CreditLimitField, "2000000")
  val s = Logic.update(m, SaveClicked)
  assertEqualInt(s.effects.count, 0, "no save effect")
  assertTrue(Forms.hasErrorFor(s.model.errors, "creditLimit"), "credit limit error")
  val shown = UiTest.fieldErrors(View.view(s.model), "Credit limit")
  assertEqualInt(shown.count, 1, "error shown under the field")
  assertEqual(shown[0], "Credit limit must be between 0 and 1000000", "message")
}

test "every invalid field is reported at once" {
  val m = edit(edit(loaded(), CustomerField.Name, "  "), CustomerField.Email, "nope")
  val s = Logic.update(m, SaveClicked)
  assertTrue(Forms.hasErrorFor(s.model.errors, "name"), "name")
  assertTrue(Forms.hasErrorFor(s.model.errors, "email"), "email")
}

test "errors clear as the user fixes them after a failed save" {
  val bad = Logic.update(edit(loaded(), CustomerField.Email, "nope"), SaveClicked).model
  val fixed = edit(bad, CustomerField.Email, "ap@acme.test")
  assertEqualInt(fixed.errors.count, 0, "errors re-validated on edit")
}

test "the key-account rule is a form-level message, not a crash" {
  val m = edit(loaded(), CustomerField.TierField, "key")
  val s = Logic.update(m, SaveClicked)
  assertEqualInt(s.effects.count, 0, "no save")
  assertEqualInt(Forms.formErrors(s.model.errors).count, 1, "one form error")
  assertTrue(UiTest.hasText(View.view(s.model), keyAccountMessage), "banner shown")
}

test "a valid save emits SaveCustomer with the parsed customer" {
  val m = edit(edit(loaded(), CustomerField.CreditLimitField, " 12000 "), CustomerField.TierField, "key")
  val s = Logic.update(m, SaveClicked)
  assertEqualInt(s.effects.count, 1, "one effect")
  match s.effects[0] {
    case SaveCustomer(c) -> {
      assertTrue(c.creditLimit.toLong() == 12000, "limit parsed")
      assertTrue(c.tier == Tier.Key, "tier parsed")
    }
    case _ -> assertTrue(false, "expected SaveCustomer")
  }
  match s.model.status {
    case Saving -> assertTrue(true, "saving")
    case _ -> assertTrue(false, "expected Saving")
  }
}

test "edits while saving are ignored" {
  val saving = Logic.update(loaded(), SaveClicked).model
  val after = edit(saving, CustomerField.Name, "Changed")
  assertEqual(after.draft.name, "Acme", "draft unchanged while saving")
}

test "a successful save notifies and returns to the list" {
  val saving = Logic.update(loaded(), SaveClicked).model
  val s = Logic.update(saving, Saved(outcome = Ok(value = sample())))
  assertEqualInt(s.effects.count, 2, "toast + navigate")
  assertTrue(isUi(s.effects[0]) and isUi(s.effects[1]), "both are UI effects")
}

test "a failed save keeps the edits and shows the error" {
  val m = edit(loaded(), CustomerField.Name, "Acme Pty")
  val saving = Logic.update(m, SaveClicked).model
  val s = Logic.update(saving, Saved(outcome = Err(error = "connection reset")))
  assertEqual(s.model.draft.name, "Acme Pty", "edits kept")
  assertTrue(UiTest.hasText(View.view(s.model), "Save failed: connection reset"), "error banner")
}

test "cancel with unsaved changes asks first" {
  val s = Logic.update(edit(loaded(), CustomerField.Name, "X"), CancelClicked)
  assertEqualInt(s.effects.count, 1, "one effect")
  match s.effects[0] {
    case Ui(Confirm(q, _)) -> assertEqual(q, "Discard your changes?", "question")
    case _ -> assertTrue(false, "expected Confirm")
  }
  val clean = Logic.update(loaded(), CancelClicked)
  match clean.effects[0] {
    case Ui(Navigate(url)) -> assertEqual(url, "/customers", "navigates straight back")
    case _ -> assertTrue(false, "expected Navigate")
  }
}

// ─── View ─────────────────────────────────────────────────────────────────────
test "typing into a field produces FieldEdited" {
  match UiTest.typeInto(View.view(loaded()), "Email", "billing@acme.test") {
    case Some(FieldEdited(f, v)) -> {
      assertTrue(f == CustomerField.Email, "field")
      assertEqual(v, "billing@acme.test", "value")
    }
    case _ -> assertTrue(false, "expected FieldEdited")
  }
}

test "the Save button is busy while saving" {
  val saving = Logic.update(loaded(), SaveClicked).model
  match UiTest.click(View.view(saving), "Save") {
    case Some(_) -> assertTrue(false, "busy Save must not click")
    case None -> assertTrue(true, "no click while saving")
  }
  match UiTest.click(View.view(loaded()), "Save") {
    case Some(SaveClicked) -> assertTrue(true, "Save clicks when editing")
    case _ -> assertTrue(false, "expected SaveClicked")
  }
}

// ─── Session ──────────────────────────────────────────────────────────────────
func program(): Program[Model, Msg, Effect] {
  return Program(update = Logic.update, view = View.view, uiEffect = Logic.uiEffect)
}

test "a session turns the confirm effect into a dialog and navigation" {
  val p = program()
  val o0 = Session.start(p, Logic.init(CustomerId.from(7)))
  assertEqualInt(o0.effects.count, 1, "load effect goes to the driver")
  val o1 = Session.dispatch(p, o0.session, Loaded(outcome = Ok(value = sample())))
  val o2 = Session.dispatch(p, o1.session, FieldEdited(field = CustomerField.Name, value = "Acme Pty"))
  val o3 = Session.dispatch(p, o2.session, CancelClicked)
  assertTrue(o3.session.dialog.isSome, "dialog shown")
  assertEqualInt(o3.effects.count, 0, "confirm is not an app effect")
  val o4 = Session.dispatch(p, o3.session, DiscardConfirmed)
  assertEqualInt(o4.commands.count, 1, "one host command")
  match o4.commands[0] {
    case NavigateTo(url) -> assertEqual(url, "/customers", "back to list")
    case _ -> assertTrue(false, "expected NavigateTo")
  }
}
