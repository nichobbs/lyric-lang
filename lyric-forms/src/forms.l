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

// ─── Field paths ──────────────────────────────────────────────────────────────
/// One step of a `FieldPath`: a named field, or a row of a list-valued field
/// identified by its stable row id (`DraftRow.id`).
pub union PathSegment {
  case Named(name: String)
  case Item(id: Int)
}

/// Where in a form a value lives: `customer.name`, or `lines[row 3].qty`.
/// Rows are addressed by their stable id rather than their position, so an
/// error stays attached to the right row when rows are added, removed or
/// reordered (docs/65 §11, D138).
pub record FieldPath {
  segments: List[PathSegment]
}

/// The empty path: the form itself.  `child(rootPath(), n)` is
/// `fieldPath(n)`.
pub func rootPath(): FieldPath {
  val segs: List[PathSegment] = newList()
  return FieldPath(segments = segs)
}

/// The path of the top-level field `name`.
pub func fieldPath(name: in String): FieldPath {
  val segs: List[PathSegment] = newList()
  segs.add(Named(name = name))
  return FieldPath(segments = segs)
}

/// `p` extended with the named field `name`.
pub func child(p: in FieldPath, name: in String): FieldPath {
  val segs: List[PathSegment] = copySegments(p)
  segs.add(Named(name = name))
  return FieldPath(segments = segs)
}

/// `p` extended with the row whose id is `id`.
pub func item(p: in FieldPath, id: in Int): FieldPath {
  val segs: List[PathSegment] = copySegments(p)
  segs.add(Item(id = id))
  return FieldPath(segments = segs)
}

/// True when `a` and `b` name the same field.
pub func samePath(a: in FieldPath, b: in FieldPath): Bool {
  if a.segments.count != b.segments.count {
    return false
  }
  var i = 0
  while i < a.segments.count {
    if not sameSegment(a.segments[i], b.segments[i]) {
      return false
    }
    i = i + 1
  }
  return true
}

/// True when `p` is `prefix` or lies below it (a row's fields lie below the
/// row, a list's rows below the list).
pub func isWithin(p: in FieldPath, prefix: in FieldPath): Bool {
  if prefix.segments.count > p.segments.count {
    return false
  }
  var i = 0
  while i < prefix.segments.count {
    if not sameSegment(p.segments[i], prefix.segments[i]) {
      return false
    }
    i = i + 1
  }
  return true
}

/// A readable, unambiguous rendering of `p`, such as `lines[#3].qty`.  Hosts
/// may use it as a DOM key; it is not meant to be parsed back.
pub func pathText(p: in FieldPath): String {
  var s = ""
  for seg in p.segments {
    match seg {
      case Named(n) -> {
        s = if s.length == 0 then n else s + "." + n
      }
      case Item(id) -> {
        s = s + "[#" + id.toString() + "]"
      }
    }
  }
  return s
}

func sameSegment(a: in PathSegment, b: in PathSegment): Bool {
  return match a {
    case Named(x) -> match b { case Named(y) -> x == y; case Item(_) -> false }
    case Item(x) -> match b { case Item(y) -> x == y; case Named(_) -> false }
  }
}

func copySegments(p: in FieldPath): List[PathSegment] {
  val segs: List[PathSegment] = newList()
  for seg in p.segments {
    segs.add(seg)
  }
  return segs
}

// ─── Errors ───────────────────────────────────────────────────────────────────
/// A single form validation failure.  Field-level cases carry the path of
/// the field they belong to; `CrossField` covers rules that span fields
/// (typically a record invariant).
pub union FieldError {
  case Required(field: FieldPath)
  case Invalid(field: FieldPath, reason: String)
  case OutOfRange(field: FieldPath, min: Long, max: Long)
  case TooLong(field: FieldPath, max: Int)
  case CrossField(message: String)
}

/// The field a `FieldError` belongs to, or `None` for cross-field errors.
pub func fieldOf(e: in FieldError): Option[FieldPath] {
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

/// The errors in `errs` that belong to exactly `field`, in order.
pub func errorsFor(errs: in List[FieldError], field: in FieldPath): List[FieldError] {
  val acc: List[FieldError] = newList()
  for e in errs {
    match fieldOf(e) {
      case Some(f) -> if samePath(f, field) { acc.add(e) }
      case None -> ()
    }
  }
  return acc
}

/// The errors in `errs` at `prefix` or below it (for example every error of
/// one row), in order.
pub func errorsWithin(errs: in List[FieldError], prefix: in FieldPath): List[FieldError] {
  val acc: List[FieldError] = newList()
  for e in errs {
    match fieldOf(e) {
      case Some(f) -> if isWithin(f, prefix) { acc.add(e) }
      case None -> ()
    }
  }
  return acc
}

/// True when `errs` holds at least one error for exactly `field`.
pub func hasErrorFor(errs: in List[FieldError], field: in FieldPath): Bool {
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

// ─── List rows ────────────────────────────────────────────────────────────────
/// One row of a list-valued field in a draft.  `id` is stable for the row's
/// lifetime and never reused within the list, so errors (`item(path, id)`),
/// widget keys and edits keep addressing the same row when rows move.
pub record DraftRow[D] {
  id: Int
  draft: D
}

/// The rows of a list-valued field.  Ids come from `nextId`, a counter held
/// in the draft itself, so allocating one is deterministic and screen logic
/// that adds rows stays pure (docs/65 §4.5).
pub record DraftRows[D] {
  rows: List[DraftRow[D]]
  nextId: Int
}

/// No rows.
pub func emptyRows[D](): DraftRows[D] {
  val rs: List[DraftRow[D]] = newList()
  return DraftRows(rows = rs, nextId = 1)
}

/// Rows holding `drafts`, in order, with ids from 1.  Build a list once
/// with this and edit it with the row operations: a rebuilt list gets new
/// ids, which errors recorded against the old rows do not refer to.
pub func rowsOf[D](drafts: in List[D]): DraftRows[D] {
  val rs: List[DraftRow[D]] = newList()
  var next = 1
  for d in drafts {
    val r: DraftRow[D] = DraftRow(id = next, draft = d)
    rs.add(r)
    next = next + 1
  }
  return DraftRows(rows = rs, nextId = next)
}

/// `rows` with `d` appended as a new row.  The new row's id is `rows.nextId`.
pub func addRow[D](rows: in DraftRows[D], d: in D): DraftRows[D] {
  val rs: List[DraftRow[D]] = newList()
  for existing in rows.rows {
    rs.add(existing)
  }
  val r: DraftRow[D] = DraftRow(id = rows.nextId, draft = d)
  rs.add(r)
  return DraftRows(rows = rs, nextId = rows.nextId + 1)
}

/// `rows` without the row `id` (unchanged when there is no such row).
pub func removeRow[D](rows: in DraftRows[D], id: in Int): DraftRows[D] {
  val rs: List[DraftRow[D]] = newList()
  for r in rows.rows {
    if r.id != id {
      rs.add(r)
    }
  }
  return DraftRows(rows = rs, nextId = rows.nextId)
}

/// `rows` with the draft of row `id` replaced by `f` of it (unchanged when
/// there is no such row).
pub func updateRow[D](rows: in DraftRows[D], id: in Int, f: in (D) -> D): DraftRows[D] {
  val rs: List[DraftRow[D]] = newList()
  for r in rows.rows {
    if r.id == id {
      val d: D = f(r.draft)
      val updated: DraftRow[D] = DraftRow(id = id, draft = d)
      rs.add(updated)
    } else {
      rs.add(r)
    }
  }
  return DraftRows(rows = rs, nextId = rows.nextId)
}

/// `rows` with row `id` moved to position `to` (clamped to the list; unchanged
/// when there is no such row).
pub func moveRow[D](rows: in DraftRows[D], id: in Int, to: in Int): DraftRows[D] {
  val found: Option[DraftRow[D]] = findRow(rows, id)
  val moving: DraftRow[D] = match found { case Some(r) -> r; case None -> return rows }
  val rest: List[DraftRow[D]] = newList()
  for r in rows.rows {
    if r.id != id {
      rest.add(r)
    }
  }
  val at = if to < 0 then 0 else if to > rest.count then rest.count else to
  val rs: List[DraftRow[D]] = newList()
  var i = 0
  while i < rest.count {
    if i == at {
      rs.add(moving)
    }
    rs.add(rest[i])
    i = i + 1
  }
  if at == rest.count {
    rs.add(moving)
  }
  return DraftRows(rows = rs, nextId = rows.nextId)
}

/// The row whose id is `id`.
pub func findRow[D](rows: in DraftRows[D], id: in Int): Option[DraftRow[D]] {
  for r in rows.rows {
    if r.id == id {
      return Some(value = r)
    }
  }
  return None
}

/// Validates every row of the list at `path` with `f`, which receives the
/// row's own path (`item(path, id)`) for its errors.  All rows are validated
/// so every error is reported at once; the result is the rows' values in
/// order, or every error found.
pub func validateRows[D, T](
  rows: in DraftRows[D],
  path: in FieldPath,
  f: in (FieldPath, D) -> Result[T, List[FieldError]],
): Result[List[T], List[FieldError]] {
  val values: List[T] = newList()
  val errs: List[FieldError] = newList()
  for r in rows.rows {
    val rowPath = item(path, r.id)
    val d: D = r.draft
    val res: Result[T, List[FieldError]] = f(rowPath, d)
    match res {
      case Ok(v) -> values.add(v)
      case Err(es) -> {
        for e in es {
          errs.add(e)
        }
      }
    }
  }
  if errs.count > 0 {
    return Err(error = errs)
  }
  return Ok(value = values)
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
