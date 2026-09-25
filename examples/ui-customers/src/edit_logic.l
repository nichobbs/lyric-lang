//! Customers.Edit.Logic — the edit-customer screen as a pure state machine
//! (docs/65-ui-library-sketch.md §4.1).
//!
//! Layer: logic.  Imports the domain, `Forms` and `Ui.Core` (data types
//! only); never `Ui.Widgets`, ports or I/O.  `update` is deterministic:
//! everything it needs arrives in the message.
@runtime_checked
package Customers.Edit.Logic

import Std.Core
import Forms.{FieldError}
import Ui.Core.{Step, UiEffect, Navigate, Confirm, Notify, ToastLevel, stay, step1, stepAll}
import Customers.Domain.{Customer, CustomerId, CustomerDraft, CustomerField, emptyCustomerDraft, toCustomerDraft, setCustomerField, validateCustomer}

pub union Status {
  case Loading
  case Editing
  case Saving
  case LoadFailed(message: String)
}

pub record Model {
  id: CustomerId
  draft: CustomerDraft
  errors: List[FieldError]
  status: Status
  dirty: Bool
  saveError: Option[String]
}

pub union Msg {
  case Loaded(outcome: Result[Customer, String])
  case FieldEdited(field: CustomerField, value: String)
  case SaveClicked
  case Saved(outcome: Result[Customer, String])
  case CancelClicked
  case DiscardConfirmed
  case RetryClicked
}

pub union Effect {
  case LoadCustomer(id: CustomerId)
  case SaveCustomer(customer: Customer)
  case Ui(effect: UiEffect[Msg])
}

pub val listUrl: String = "/customers"

pub func init(id: in CustomerId): Step[Model, Effect] {
  val m = Model(
    id = id,
    draft = emptyCustomerDraft(),
    errors = noErrors(),
    status = Status.Loading,
    dirty = false,
    saveError = None
  )
  return step1(m, LoadCustomer(id = id))
}

pub func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case Loaded(Ok(c)) -> stay(
      m.copy(
        draft = toCustomerDraft(c),
        status = Status.Editing,
        dirty = false,
        saveError = None
      )
    )
    case Loaded(Err(e)) -> stay(m.copy(status = LoadFailed(message = e)))
    case RetryClicked -> step1(m.copy(status = Status.Loading), LoadCustomer(id = m.id))
    case FieldEdited(f, v) -> onEdit(m, f, v)
    case SaveClicked -> onSave(m)
    case Saved(Ok(c)) -> {
      val saved = m.copy(
        draft = toCustomerDraft(c),
        errors = noErrors(),
        status = Status.Editing,
        dirty = false,
        saveError = None
      )
      val es: List[Effect] = newList()
      es.add(Ui(effect = Notify(message = "Customer saved", level = ToastLevel.Success)))
      es.add(Ui(effect = Navigate(url = listUrl)))
      stepAll(saved, es)
    }
    case Saved(Err(e)) -> stay(m.copy(status = Status.Editing, saveError = Some(value = e)))
    case CancelClicked -> if m.dirty then step1(m, Ui(effect = Confirm(question = "Discard your changes?", onYes = DiscardConfirmed))) else step1(m, Ui(effect = Navigate(url = listUrl)))
    case DiscardConfirmed -> step1(m.copy(dirty = false), Ui(effect = Navigate(url = listUrl)))
  }
}

// Edits are ignored while loading or saving, so a late keystroke cannot
// change a draft that is already on its way to the repository.
func onEdit(m: in Model, f: in CustomerField, v: in String): Step[Model, Effect] {
  return match m.status {
    case Editing -> {
      val d = setCustomerField(m.draft, f, v)
      // Re-validate only once the user has tried to save, so a half-typed
      // form is not covered in errors.
      val errs = if m.errors.count > 0 then errorsOf(d, m.id) else m.errors
      stay(m.copy(draft = d, errors = errs, dirty = true, saveError = None))
    }
    case _ -> stay(m)
  }
}

func onSave(m: in Model): Step[Model, Effect] {
  return match m.status {
    case Editing -> match validateCustomer(m.draft, m.id) {
      case Ok(c) -> step1(
        m.copy(errors = noErrors(), status = Status.Saving, saveError = None),
        SaveCustomer(customer = c)
      )
      case Err(errs) -> stay(m.copy(errors = errs))
    }
    case _ -> stay(m)
  }
}

func errorsOf(d: in CustomerDraft, id: in CustomerId): List[FieldError] {
  return match validateCustomer(d, id) { case Ok(_) -> noErrors(); case Err(errs) -> errs }
}

func noErrors(): List[FieldError] {
  val none: List[FieldError] = newList()
  return none
}

/// True when the screen's effect is one the UI runtime handles
/// (`Program.uiEffect`).
pub func uiEffect(e: in Effect): Option[UiEffect[Msg]] {
  return match e { case Ui(u) -> Some(value = u); case _ -> None }
}
