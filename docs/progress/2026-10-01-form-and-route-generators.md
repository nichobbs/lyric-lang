# Form and route generators; generator request schema 2 (docs/65 U4, D151)

Phase U4 of docs/65: `@generate(Forms.Derive)` and `@generate(Ui.Routes)`,
on the request schema D138 (Q-UI-004) specified.

- **Request schema 2** (`Lyric.Generator`, `Lyric.GeneratorSdk`).
  - The descriptor is built from the parsed declaration. It carries:
    - annotations on the type, fields and cases, with argument source text;
    - type parameters and field defaults;
    - union and enum cases;
    - invariants as source text, with their `@message`;
    - the `Opaque` and `Enum` kinds.
  - A top-level `declarations` array lists the same-file enum, distinct and
    alias declarations the type names.
  - The compiler sends `"2"`; the SDK accepts `"1"` and `"2"` and skips
    declaration kinds it does not know.
- **`invariant: expr @message("...")`** parses (P0345 for anything else);
  the formatter keeps it.
- **A generic type's span ends at its `]`** (it stopped at the last type
  argument). Generators read a field's type as source text, so
  `Option[String]` arrived as `Option[String`.
- **Generated imports go on the `package` line** (`package P; import A`),
  so a generator never shifts the consumer's line numbers.
- **`Forms.Derive`** (`lyric-forms/derive/`).
  - **Emits:** a record's or opaque type's draft, field enum, name lookup,
    schema, empty and existing drafts, value/set accessors and `validateT`.
  - **Field types:** `String`/`Bool`/`Int`/`Long`, `Option`, and same-file
    enum, distinct and range types; any other type via
    `@form_parse`/`@form_format`.
  - **Annotations:** `@readonly`, `@label`, `@multiline`, `@email` and
    `@maxLength`.
  - **Invariants** are checked before construction and reported as
    `CrossField`.
  - **Diagnostics:** FD001–FD006.
  - `Forms.Parse` gains `noteError`, `requiredTextUpTo`, `optionalTextUpTo`,
    `wholeNumber`, `optionalWholeNumber`, `optionalEmail` and `flag` for the
    generated code.
- **`Ui.Routes`** (`lyric-ui/routes/`).
  - **Emits:** `parseT(url)` and `tUrl(r)` from `@path` on union cases.
  - **Segments:** `{field}` and `{field:Long}`; values go through
    `tryFrom` for range types.
  - **Encoding** uses the new pure `Ui.Routing` package (percent
    encoding/decoding, path splitting).
  - **Diagnostics:** RT001–RT006.
- **Layers.** The `ui` preset lets logic, effects and views import
  `Ui.Routing`.
- **Example.** `examples/ui-customers` derives its form and routes. The
  hand-written form code is gone, and a `Customers.Routes` logic package
  replaces the URL string handling in `main.l` and the list view.

Tests:
- `generator/generator_self_test.l`: declarations, splicing onto the
  package line, the schema-2 descriptors.
- `parser_self_test.l` and `fmt_self_test.l`: `@message`.
- `layers_self_test.l`: `Ui.Routing` per layer.
- `lyric-generator-sdk` tests: schema-2 round trips, declarations,
  unknown kinds.
- `lyric-forms` tests: the new parsers.
- `lyric-forms/derive` and `lyric-ui/routes` tests: generated code and
  each diagnostic.
- `lyric-ui` `routing_tests.l`.
- `examples/ui-customers` on dotnet and the JVM (both in CI) and the
  browser e2e.

Found along the way:
- #7906: MSIL types a bare `None` arm from the scrutinee when its only
  sibling returns. The generators annotate the affected bindings.
- #7907: nested records, `List` fields, dates and route query parameters.
- #7908: `[x].toList()` where a `List` is expected type-checks but fails
  codegen on both backends.
