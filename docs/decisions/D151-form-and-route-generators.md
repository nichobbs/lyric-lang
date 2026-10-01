# D151 — Generator request schema 2, `Forms.Derive` and `Ui.Routes`

**Status:** accepted, implemented

Implements phase U4 of docs/65: request schema 2 as specified by D138
(Q-UI-004), refined below, and the two UI generators built on it.

## Context

D150 made custom generators usable, but schema 1 described a type by its
fields alone: no annotations, no invariants, no union cases. That is not
enough for a form (labels, input hints, invariant messages) or for routes
(`@path` on union cases). D138 specified schema 2; this entry records how
it was built and the two generators that use it.

## Decision

1. **Schema 2 is a superset of schema 1.** The compiler always sends
   `"schemaVersion":"2"`, and `Lyric.GeneratorSdk.parseRequest` accepts
   both 1 and 2. This refines D138's "generators declaring schema 1 keep
   receiving schema 1". Generators are only local dependencies built from
   source against the in-tree SDK (D150), and every key schema 1 had is
   unchanged, so no generator declares a version and none needs one.
2. **What schema 2 adds:**
   - every annotation on the type, its fields and its cases, with each
     argument's source text;
   - type parameters;
   - field defaults, as source text;
   - a union's or enum's cases, with their fields;
   - each `invariant:` as source text, with its position and optional
     `@message`;
   - the item kinds `Opaque` and `Enum`;
   - a top-level `declarations` array.
3. **`declarations` describes same-file types the annotated type names.**
   The array holds the same-file enum, distinct and alias declarations whose
   names appear in the annotated type's source:
   - an enum's cases, with their annotations;
   - a distinct type's underlying type and range bounds, as source text,
     with whether the upper bound is inclusive.

   The generator still never sees the rest of the program: the preprocessor
   runs on one file before type checking. An SDK reader skips a declaration
   kind it does not know, so a newer compiler can describe more.
4. **`invariant: expr @message("...")`** parses; the message is kept on the
   invariant (P0345 for anything else after an invariant).
5. **Generated imports join the `package` line** (`package P; import A`), so
   splicing them never moves the consumer's own lines and its diagnostics
   keep their line numbers.
6. **`Forms.Derive`** (`lyric-forms/derive/`, a `source-generator`).
   - **Supported types:** a record or opaque type, non-generic. A field is
     `String`, `Bool`, `Int`, `Long`, `Option` of one of those, a
     same-file enum, or a same-file distinct or range type over
     `String`/`Int`/`Long`. Any other type takes `@form_parse(f)` with
     `@form_format(g)`.
   - **What it emits:** the draft record, the field enum, name lookup, the
     schema, the empty and existing drafts, value/set accessors, and
     `validateT`.
   - **`validateT`:**
     - parses every field and reports every error at once;
     - checks each invariant, copied as source, before construction, and
       maps a failure to `CrossField(@message)`;
     - then constructs.
   - **Field annotations:** `@readonly` (not edited; a `validateT`
     parameter), `@label`, `@multiline`, `@email`, `@maxLength`. An enum
     case takes `@label` for its choice label.
   - **Booleans:** a `Bool` draft is the checkbox's `"true"`/`"false"` text,
     so every field is set through one `(field, text)` message.
   - **Diagnostics:** `FD001`–`FD006`.
7. **`Ui.Routes`** (`lyric-ui/routes/`, a `source-generator`).
   - **What it emits:** for a non-generic union whose cases carry
     `@path("/a/{field}")`, `parseT(url): Option[T]`, which tries cases in
     declaration order, and `tUrl(r): String`.
   - **Fields:** every case field appears in its path exactly once.
   - **`{field:Long}`** (or `:Int`, `:String`) names a segment's type, for a
     distinct type declared in another file; the value is converted with
     `tryFrom`, so a value outside a range type does not match.
   - **Literal segments** are unreserved characters only. Field values are
     percent-encoded through the new pure `Ui.Routing` package.
   - **Diagnostics:** `RT001`–`RT006`. Two cases with the same path shape
     are RT005.
8. **The `ui` layer preset allows `Ui.Routing`** in logic, effects and view
   packages, so pages can be named in logic and linked in views. The domain
   stays closed to `Ui.*`.

## Consequences

- `examples/ui-customers` derives its form and its routes; the hand-written
  form code that served as the golden output (docs/65 §11.6) is gone.
- **Not yet supported:**
  - `Forms.Derive` does not derive nested records or `List[T]` fields
    (`DraftRows`), or dates without `@form_parse`;
  - routes do not carry query parameters.

  All of these are tracked in #7907.
- **MSIL bug #7906** (a bare `None` arm typed from the scrutinee) surfaced
  while writing the generators. Their unannotated bindings are annotated
  until it is fixed.
