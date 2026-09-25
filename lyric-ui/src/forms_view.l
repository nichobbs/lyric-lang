//! Ui.Forms — renders a `Forms.FormSchema` as widgets
//! (docs/65-ui-library-sketch.md §11.1, §11.6).
//! Stability: @experimental — Phase U1 of docs/65.
//!
//! A view layer helper: given a schema, the draft's current text for each
//! field, and the validation errors, it produces one labelled field per
//! schema entry with the input kind, bounds and error messages the schema
//! describes.  Screens can use the result as-is (scaffolding) or replace
//! individual fields with hand-written views.
@runtime_checked
package Ui.Forms

import Std.Core
import Forms.{FormSchema, FieldSpec, FieldError, InputKind, errorsFor, messageOf}
import Ui.Core.{View}
import Ui.Widgets.{field, textInput, textArea, numberInput, checkbox, select, SelectChoice, NumberBounds, InputOpts, inputOpts}

/// One field view per schema entry, in schema order.  `valueOf` returns the
/// draft text for a field name; `onEdit` builds the message for an edit of
/// a field (name, new text).
pub func formFields[Msg](
  schema: in FormSchema,
  valueOf: in (String) -> String,
  errors: in List[FieldError],
  onEdit: in (String, String) -> Msg,
): List[View[Msg]] {
  val acc: List[View[Msg]] = newList()
  for spec in schema.fields {
    acc.add(fieldView(spec, valueOf(spec.name), errors, onEdit))
  }
  return acc
}

/// The view of one field.
pub func fieldView[Msg](
  spec: in FieldSpec,
  value: in String,
  errors: in List[FieldError],
  onEdit: in (String, String) -> Msg,
): View[Msg] {
  val name = spec.name
  val onInput = { s: String -> onEdit(name, s) }
  val opts = optsFor(spec)
  val input: View[Msg] = match spec.kind {
    case Text -> textInput("text", value, onInput, opts)
    case Email -> textInput("email", value, onInput, opts)
    case MultilineText -> textArea(value, onInput, opts)
    case Date -> textInput("date", value, onInput, opts)
    case Number -> {
      val bounds: Option[NumberBounds] = match spec.bounds {
        case Some(b) -> Some(value = NumberBounds(min = b.min, max = b.max))
        case None -> None
      }
      numberInput(value, onInput, opts, bounds)
    }
    case Checkbox -> checkbox(spec.label, value == "true", onInput)
    case Select -> {
      val choices: List[SelectChoice] = newList()
      for c in spec.choices {
        choices.add(SelectChoice(value = c.value, label = c.label))
      }
      select(value, choices, onInput)
    }
  }
  val messages: List[String] = newList()
  for e in errorsFor(errors, name) {
    messages.add(messageOf(e, spec.label))
  }
  return field(spec.label, messages, input)
}

/// The input options (`maxLength`, bounds, required) a field's spec implies.
/// Public because the generic `fieldView` calls it and a generic body is
/// compiled into each calling package.
pub func optsFor(spec: in FieldSpec): InputOpts {
  val ml = match spec.maxLength { case Some(n) -> n; case None -> 0 }
  return InputOpts(placeholder = "", required = spec.required, readonly = spec.readonly, maxLength = ml)
}
