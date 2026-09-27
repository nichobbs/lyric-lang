# `@generate(Json)` decodes nested records from one parsed document (#7347)

`Lyric.Derives` now gives every `@generate(Json)` record a public
`T.fromJsonElement(elem: in JsonElement): Result[T, String]` holding the field
decoder, and `T.fromJson(json: in String)` parses once, decodes through it and
disposes the document when it returns. A nested `@generate(Json)` record,
as a field or a slice element, is decoded from its child element with
`Child.fromJsonElement(elem)` instead of `Child.fromJson(getRawText(elem))`,
so one `fromJson` call parses its body once however deep the records nest.
Nested types the pass cannot see a `fromJsonElement` for keep the
`fromJson(String)` call; a hand-written `fromJson` gets a forwarding
`fromJsonElement`. Decoded values and every `Err` message are unchanged,
including the fail-closed paths of #7251/#7401. See D-progress-1002.

The JVM backend now registers derive-synthesised functions under the same
keys as hand-written dot-named ones, so `T.fromJson(...)` in a
value-producing `if`/`match` arm no longer fails codegen with a stackmap
depth mismatch, and `fromJsonElement` names its parameter type by its
declaring package (`Std.JsonHost.JsonElement`) so it resolves on the JVM. The JVM kernel's dead, non-fail-closed
`lyricJsonGet*Slice` readers are removed; `Std.Json`'s public string readers
stay (`Std.Rest` uses them).

Benchmark (`benchmarks/bench_json.l`, new, wired into `bench.yml`;
`--runs 15 --warmup 5`, dotnet Release, 200 decodes per run; ranges over
three runs of each build, min / mean):

| Benchmark | Before | After |
|---|---|---|
| `benchFromJsonWide20` (flat 20 fields) | 3.7–4.0 / 4.1–4.3 ms | 3.8–4.0 / 3.9–4.2 ms |
| `benchFromJsonNested` (20 fields, 4 nested records, 20-element record slice) | 29.0–33.0 / 37.3–38.8 ms | 21.0–22.6 / 28.2–31.6 ms |
| `benchStringReadersWide20` (reference: 20 one-parse-each string reads) | 6.4–6.6 / 9.8–12.5 ms | not affected |

The flat record already parsed once before this change; the nested order
drops from 25 parses to one, about a quarter off its decode time.

Verified on dotnet: `derives_self_test.l` (56 cases, 5 new),
`generator_self_test.l`, `json_tests.l`, `rest_tests.l` and the new
`lyric-stdlib/tests/json_generate_tests.l` (nested decode, round trip, nested
and slice rejections with exact messages, malformed and non-object bodies,
direct `fromJsonElement`, hand-written nested decoder), which joins the
stdlib dotnet suite loop in CI and passes unchanged on the pre-change compiler
apart from the direct `fromJsonElement` case; a two-package project with a
record nesting an imported `@generate(Json)` record; the ecosystem suites
(no new failures). On the JVM: `json_tests.l`, and the derive/dot-named
function self-tests CI runs there (`map_key`, `synthesized_method`,
`distinct_ops`, `range_subtype_arith`, `module_val_deps`, `record_method`,
`self_method_call`, `implicit_self`, `stackmap_expr_branch`,
`silent_miscompile_guard`, `method_scrutinee`, `projectable`) plus the
lyric-storage, lyric-resilience and lyric-health JVM suites. Nested records
on the JVM still wait on two backend gaps recorded in D-progress-1002 (#7501, #7502).

Docs: docs/01-language-reference.md §`@generate`, docs/40-source-generators.md,
book chapters 12 (§12.7) and 30 (§30.1.2).
