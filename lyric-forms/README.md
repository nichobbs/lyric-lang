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
| `Forms` | `FieldError`, `messageOf`, `errorsFor`, `formErrors`; `FormSchema`, `FieldSpec`, `InputKind` and the schema builders |
| `Forms.Parse` | `requiredText`, `optionalText`, `withinLength`, `longInRange`, `optionalLongInRange`, `oneOf`, `email`, and `collect` |

## Validate function

```lyric
import Forms.{FieldError, CrossField}
import Forms.Parse

pub func validateCustomer(d: in CustomerDraft, id: in CustomerId): Result[Customer, List[FieldError]] {
  val errs: List[FieldError] = newList()
  val name  = Parse.collect(errs, Parse.requiredText("name", d.name), "")
  val email = Parse.collect(errs, Parse.email("email", d.email), "")
  val limit = Parse.collect(errs, Parse.longInRange("creditLimit", d.creditLimit, 0, 1_000_000), 0)
  if errs.length > 0 {
    return Err(error = errs)
  }
  return Ok(value = Customer(id = id, name = name, email = email, creditLimit = limit))
}
```

`collect` returns the parsed value or a fallback, appending the error to a
list the caller created, so every invalid field is reported at once.

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
