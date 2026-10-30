# Ui.Routes: query parameters (#7907, part)

`@query(field)` / `@query(field, "name")` on a route case reads an `Option[T]`
field from the query string instead of a path segment (D278, docs/65 §6.1).

- `lyric-ui/routes/src/routes.l`: parsing, `routeUrl` output, diagnostic `RT007`.
- `lyric-ui/src/routing.l`: `queryPresent`, `queryValue`, `withQuery`.
- Tests: `lyric-ui/tests/routing_tests.l` (3 cases),
  `lyric-ui/routes/tests/routes_tests.l` (generated-source and diagnostics),
  and `examples/ui-customers/tests/routes_tests.l`, which runs the generated
  `parseRoute`/`routeUrl` of a new `CustomerSearch` route on both targets.
- Docs: docs/65 §6.1, `lyric-ui/README.md`, book chapter 31, quick-reference `RT007`.

Still open in #7907: nested derived records, `List[T]` / `DraftRows` fields,
`Instant`/date inputs, and cross-file declarations for the preprocessor.
