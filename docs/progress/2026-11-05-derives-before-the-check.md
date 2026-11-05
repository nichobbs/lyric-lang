# Derives run before the checker (docs/70 phase 3b slice S1, D390)

`@derive` and `@generate(Json)` output is now produced before type checking, so
the checker, mode checker and contract elaborator see it as user code. Generated
nodes take unique spans from the new `Lyric.Expand` allocator (with the cause's
line and column) and a diagnostic found in them is reported at the declaration
that caused the code; warnings in generated code are dropped. See D390.
