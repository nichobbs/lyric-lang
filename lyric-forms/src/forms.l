//! Forms — pure, UI-independent building blocks for editing domain values
//! through forms (docs/65-ui-library-sketch.md §11).
//! Stability: @experimental — Phase U1 of docs/65.
//!
//! A form never edits a domain value directly.  It edits a *draft* (the raw
//! text the user typed, which may be invalid) and a single validate function
//! maps the draft to the domain value or to a list of `FieldError`s.  This
//! package owns the error type, the form schema a renderer consumes, and the
//! `Forms.Parse` helpers a validate function is built from.
//!
//! Nothing here depends on a UI library, so domain packages may import it
//! (docs/65 §5.2: `lyric-forms` is `pure`).
@runtime_checked
package Forms

import Std.Core

// ─── Errors ───────────────────────────────────────────────────────────────────
/// A single form validation failure.  Field-level cases carry the field's
/// schema name (`FieldSpec.name`); `CrossField` covers rules that span fields
/// (typically a record invariant).
pub union FieldError {
  case Required(field: String)
  case Invalid(field: String, reason: String)
  case OutOfRange(field: String, min: Long, max: Long)
  case TooLong(field: String, max: Int)
  case CrossField(message: String)
}

/// The field a `FieldError` belongs to, or `None` for cross-field errors.
pub func fieldOf(e: in FieldError): Option[String] {
  return match e {
    case Required(f) -> Some(value = f)
    case Invalid(f, _) -> Some(value = f)
    case OutOfRange(f, _, _) -> Some(value = f)
    case TooLong(f, _) -> Some(value = f)
    case CrossField(_) -> None
  }
}

/// A human-readable message for `e`, using `label` for the field's display
/// name.  Cross-field errors ignore `label`.
pub func messageOf(e: in FieldError, label: in String): String {
  return match e {
    case Required(_) -> label + " is required"
    case Invalid(_, reason) -> label + " " + reason
    case OutOfRange(_, lo, hi) -> label + " must be between " + lo.toString() + " and " + hi.toString()
    case TooLong(_, n) -> label + " must be at most " + n.toString() + " characters"
    case CrossField(m) -> m
  }
}

/// The errors in `errs` that belong to `field`, in order.
pub func errorsFor(errs: in List[FieldError], field: in String): List[FieldError] {
  val acc: List[FieldError] = newList()
  for e in errs {
    match fieldOf(e) {
      case Some(f) -> if f == field { acc.add(e) }
      case None -> ()
    }
  }
  return acc
}

/// True when `errs` holds at least one error for `field`.
pub func hasErrorFor(errs: in List[FieldError], field: in String): Bool {
  return errorsFor(errs, field).count > 0
}

/// The cross-field (form-level) errors in `errs`, in order.
pub func formErrors(errs: in List[FieldError]): List[FieldError] {
  val acc: List[FieldError] = newList()
  for e in errs {
    match fieldOf(e) {
      case Some(_) -> ()
      case None -> acc.add(e)
    }
  }
  return acc
}

// ─── Schema ───────────────────────────────────────────────────────────────────
/// The kind of input a renderer should use for a field.
pub enum InputKind {
  case Text
  case MultilineText
  case Email
  case Number
  case Checkbox
  case Select
  case Date
}

/// Inclusive numeric bounds of a `Number` field.
pub record Bounds {
  min: Long
  max: Long
}

/// One option of a `Select` field.
pub record Choice {
  value: String
  label: String
}

/// Everything a renderer needs to know about one field.  Bounds and
/// `required` are advisory for the renderer (instant feedback); the validate
/// function remains authoritative.
pub record FieldSpec {
  name: String
  label: String
  kind: InputKind
  required: Bool
  readonly: Bool
  bounds: Option[Bounds]
  maxLength: Option[Int]
  choices: List[Choice]
}

/// An ordered list of field specs.
pub record FormSchema {
  fields: List[FieldSpec]
}

/// A plain, optional, editable field of `kind` with no bounds.
pub func fieldSpec(name: in String, label: in String, kind: in InputKind): FieldSpec {
  return FieldSpec(
    name = name,
    label = label,
    kind = kind,
    required = false,
    readonly = false,
    bounds = None,
    maxLength = None,
    choices = newList()
  )
}

/// `spec`, marked required.
pub func required(spec: in FieldSpec): FieldSpec {
  return FieldSpec(
    name = spec.name,
    label = spec.label,
    kind = spec.kind,
    required = true,
    readonly = spec.readonly,
    bounds = spec.bounds,
    maxLength = spec.maxLength,
    choices = spec.choices
  )
}

/// `spec`, marked read-only.
pub func readonly(spec: in FieldSpec): FieldSpec {
  return FieldSpec(
    name = spec.name,
    label = spec.label,
    kind = spec.kind,
    required = spec.required,
    readonly = true,
    bounds = spec.bounds,
    maxLength = spec.maxLength,
    choices = spec.choices
  )
}

/// `spec`, with inclusive numeric bounds.
pub func bounded(spec: in FieldSpec, min: in Long, max: in Long): FieldSpec
  requires: min <= max
{
  return FieldSpec(
    name = spec.name,
    label = spec.label,
    kind = spec.kind,
    required = spec.required,
    readonly = spec.readonly,
    bounds = Some(value = Bounds(min = min, max = max)),
    maxLength = spec.maxLength,
    choices = spec.choices
  )
}

/// `spec`, with a maximum text length.
pub func maxLength(spec: in FieldSpec, n: in Int): FieldSpec
  requires: n > 0
{
  return FieldSpec(
    name = spec.name,
    label = spec.label,
    kind = spec.kind,
    required = spec.required,
    readonly = spec.readonly,
    bounds = spec.bounds,
    maxLength = Some(value = n),
    choices = spec.choices
  )
}

/// `spec`, with the choices of a `Select` field.
pub func withChoices(spec: in FieldSpec, choices: in List[Choice]): FieldSpec {
  return FieldSpec(
    name = spec.name,
    label = spec.label,
    kind = spec.kind,
    required = spec.required,
    readonly = spec.readonly,
    bounds = spec.bounds,
    maxLength = spec.maxLength,
    choices = choices
  )
}

/// A schema of `fields` in order.
pub func schema(fields: in List[FieldSpec]): FormSchema {
  return FormSchema(fields = fields)
}

/// The spec named `name` in `s`.
pub func specOf(s: in FormSchema, name: in String): Option[FieldSpec] {
  for f in s.fields {
    if f.name == name {
      return Some(value = f)
    }
  }
  return None
}

/// The display label of the field named `name`, or `name` itself when the
/// schema has no such field.
pub func labelOf(s: in FormSchema, name: in String): String {
  return match specOf(s, name) { case Some(f) -> f.label; case None -> name }
}
