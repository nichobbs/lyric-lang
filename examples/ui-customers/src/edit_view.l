//! Customers.Edit.View — presentation of the edit-customer screen
//! (docs/65-ui-library-sketch.md §4.3).
//!
//! Layer: view.  Builds `View` values from the model; never performs I/O
//! and never decides what a message does.  Most fields come from the form
//! schema (`Ui.Forms`); the page chrome and actions are written by hand.
@runtime_checked
package Customers.Edit.View

import Std.Core
import Forms
import Forms.{FieldError, messageOf}
import Ui.Core.{View}
import Ui.Widgets
import Ui.Forms
import Customers.Domain.{CustomerField, customerSchema, customerDraftValue, customerFieldNamed, CustomerDraft}
import Customers.Edit.Logic.{Model, Msg, Status, Loading, Editing, Saving, LoadFailed, FieldEdited, SaveClicked, CancelClicked, RetryClicked}

pub func view(m: in Model): View[Msg] {
  return match m.status {
    case Loading -> Widgets.spinner("Loading customer")
    case LoadFailed(message) -> {
      val cs: List[View[Msg]] = newList()
      cs.add(Widgets.banner("error", "Could not load the customer: " + message))
      cs.add(Widgets.button("Retry", RetryClicked))
      Widgets.column(cs)
    }
    case _ -> editor(m)
  }
}

func editor(m: in Model): View[Msg] {
  val saving = match m.status {
    case Saving -> true
    case _ -> false
  }
  val body: List[View[Msg]] = newList()
  match m.saveError {
    case Some(e) -> body.add(Widgets.banner("error", "Save failed: " + e))
    case None -> ()
  }
  for e in Forms.formErrors(m.errors) {
    body.add(Widgets.banner("warning", messageOf(e, "")))
  }
  val draft = m.draft
  val fields = Ui.Forms.formFields(
    customerSchema(),
    { name: String -> valueOf(draft, name) },
    m.errors,
    { name: String, value: String -> edited(name, value) }
  )
  for f in fields {
    body.add(f)
  }
  val actions: List[View[Msg]] = newList()
  actions.add(Widgets.button("Cancel", CancelClicked))
  actions.add(Widgets.primaryButton("Save", SaveClicked, saving))
  body.add(Widgets.row(actions))

  val page: List[View[Msg]] = newList()
  page.add(Widgets.heading(1, "Customer " + m.id.toString()))
  page.add(Widgets.form(SaveClicked, body))
  return Widgets.column(page)
}

func valueOf(d: in CustomerDraft, name: in String): String {
  return match customerFieldNamed(name) {
    case Some(f) -> customerDraftValue(d, f)
    case None -> ""
  }
}

// Schema field names always come from `customerSchema()`, so an unknown
// name is a programming error in this package, not a user error.
func edited(name: in String, value: in String): Msg {
  return match customerFieldNamed(name) {
    case Some(f) -> FieldEdited(field = f, value = value)
    case None -> panic("edit view: schema field '" + name + "' has no CustomerField")
  }
}
