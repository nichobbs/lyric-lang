# lyric-forms

Pure, UI-independent building blocks for editing domain values through forms
(`docs/65-ui-library-sketch.md` §11, D137).

A form never edits a domain value directly. It edits a **draft**: the raw
text the user typed, which may be invalid. A single validate function maps
the draft to the domain value or to every problem with it. This library owns
the error type, the form schema a renderer consumes, and the parsers a
validate function is built from.

It has no UI dependency, so domain packages may import it. `lyric-ui`'s
`Ui.Forms` renders a `FormSchema` as widgets.

## Packages

| Package | Contents |
|---|---|
| `Forms` | `FieldPath` (`rootPath`, `fieldPath`, `child`, `item`, `samePath`, `isWithin`, `pathText`); `FieldError`, `fieldOf`, `messageOf`, `errorsFor`, `errorsWithin`, `hasErrorFor`, `formErrors`; `DraftRows` (`emptyRows`, `rowsOf`, `addRow`, `removeRow`, `updateRow`, `moveRow`, `findRow`, `validateRows`); `FormSchema`, `FieldSpec`, `InputKind` and the schema builders |
| `Forms.Parse` | `requiredText`, `optionalText`, `withinLength`, `longInRange`, `optionalLongInRange`, `oneOf`, `email`, and `collect` |

## Validate function

```lyric
import Forms.{FieldError, CrossField, fieldPath}
import Forms.Parse

pub func validateCustomer(d: in CustomerDraft, id: in CustomerId): Result[Customer, List[FieldError]] {
  val errs: List[FieldError] = newList()
  val name  = Parse.collect(errs, Parse.requiredText(fieldPath("name"), d.name), "")
  val email = Parse.collect(errs, Parse.email(fieldPath("email"), d.email), "")
  val limit = Parse.collect(errs, Parse.longInRange(fieldPath("creditLimit"), d.creditLimit, 0, 1_000_000), 0)
  if errs.count > 0 {
    return Err(error = errs)
  }
  return Ok(value = Customer(id = id, name = name, email = email, creditLimit = limit))
}
```

`collect` returns the parsed value or a fallback, appending the error to a
list the caller created, so every invalid field is reported at once.

## List fields

Rows of a list-valued field live in a `DraftRows[D]`. Each row gets a
stable id from a counter in the draft, and errors address a row by that id
(`child(item(fieldPath("lines"), id), "qty")`), so they stay on the right
row when rows are added, removed or reordered (docs/65 §11.7, D138).
`rowsOf` numbers rows from 1, so build a list with it once (when the form
opens) and edit it with the row operations afterwards; rebuilding it would
give rows new ids that older errors do not refer to:

```lyric
val none: DraftRows[LineDraft] = Forms.emptyRows()
val lines = Forms.addRow(Forms.addRow(none, LineDraft(sku = "", qty = "")), LineDraft(sku = "A-1", qty = "2"))
match Forms.validateRows(lines, fieldPath("lines"), validateLine) {
  case Ok(values) -> ...
  case Err(errs) -> ...   // each error under lines[#id].<field>
}
```

## Schema

```lyric
val fs: List[FieldSpec] = newList()
fs.add(Forms.required(Forms.fieldSpec("name", "Name", InputKind.Text)))
fs.add(Forms.bounded(Forms.fieldSpec("creditLimit", "Credit limit", InputKind.Number), 0, 1_000_000))
val schema = Forms.schema(fs)
```

Bounds, `required` and `maxLength` are advisory for renderers (instant
feedback in the browser); the validate function remains authoritative.

## Error messages

`messageOf(error, label)` produces the user-facing text:

| Error | Message |
|---|---|
| `Required` | `Name is required` |
| `Invalid` | `Email must be an email address` |
| `OutOfRange` | `Credit limit must be between 0 and 1000000` |
| `TooLong` | `Name must be at most 100 characters` |
| `CrossField` | the message as given |

## Future

`@generate(Forms.Derive)` (docs/65 §11.2, phase U4) will derive the draft
record, field enum, schema, `toDraft`, `setField` and `validate` from a
domain type, including range subtypes and invariants.
`examples/ui-customers/src/domain.l` holds the hand-written equivalent,
which is the generator's golden output.

## Tests

```sh
lyric test --manifest lyric-forms/lyric.toml
```
