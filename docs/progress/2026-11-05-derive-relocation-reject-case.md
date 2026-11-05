# Reject-corpus case for an error in derived code (docs/70 phase 3b S1 follow-up, D390)

`derive_ord_on_enum_field` pins the end-to-end behaviour D390 introduced: a
derived body the checker rejects (`@derive(Ord)` on a record with an enum
field) is reported as T0033 at the `@derive`, with "(in code generated for this
declaration)", on dotnet and the JVM. A comment on `pipeCheckAndMono` records
that its sink must be the one every later gate uses, since the derive records
its generated spans there.
