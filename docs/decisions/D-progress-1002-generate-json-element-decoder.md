# D-progress-1002 — `@generate(Json)` decodes from one parsed document (#7347)

**Status:** shipped

Fixes #7347.

## Problem

Issue #7347 describes `@generate(Json)` stubs reading every field through the
string-based `Std.Json.lyricJsonGet*` readers, each of which parses the whole
body. The self-hosted synthesiser (`Lyric.Derives`) had already moved past
that for the fields of one record: its `fromJson` parsed the body once with
`tryParseJson` and walked the fields with `tryGetProperty` and the element
getters. What remained was the case the issue calls out for nested records.
A field or slice element whose type is another `@generate(Json)` record was
decoded as `Child.fromJson(Std.Json.getRawText(elem))`: the child's element
was serialised back to text and parsed again, once per nested value and once
more per level of nesting. An order with a customer, two addresses and twenty
line items parsed 25 documents.

## Decision

1. Every `@generate(Json)` record gets a third synthesised function,
   `pub func T.fromJsonElement(elem: in JsonElement): Result[T, String]`
   (the parameter spelled `Std.JsonHost.JsonElement`, see JVM below),
   with the visibility of the record. It holds the field decoder that
   `fromJson` used to hold.
2. `T.fromJson(json: in String)` parses once, defers `disposeJson` on the
   document and returns `T.fromJsonElement(rootElement(doc))`. The document is
   disposed once, when the outer `fromJson` returns.
3. A nested record field, or a slice element of record type, is decoded with
   `Child.fromJsonElement(elem)` when the synthesiser can see that `Child` has
   one: `Child` is a `@generate(Json)` record, or has a hand-written
   `Child.fromJsonElement`, in the same file (a multi-file package is merged
   into one file first) or in an imported package. A record declared in the
   file shadows an imported one of the same name.
4. Any other nested type keeps the `Child.fromJson(getRawText(elem))` call.
   `fromJson(String)` is the one entry point a hand-written decoder is sure to
   have, so a nested type whose decoder the pass cannot see (a record without
   `@generate(Json)`, or one reached only through restored-package metadata)
   still compiles and still decodes.
5. A hand-written function wins over a synthesised one of the same name, as
   for every other derive. A hand-written `fromJson` without a hand-written
   `fromJsonElement` gets a synthesised `fromJsonElement` that forwards the
   element's raw text to it, so a record nesting the type still runs the
   author's decoder. A hand-written `fromJsonElement` is called by the
   synthesised `fromJson` and by nesting records.

`fromJsonElement` is public API: it lets a caller decode a record from part
of a document it already holds (an envelope's `payload` property, one element
of an array) without re-serialising it.

## Behaviour kept

Decoding results and error text are unchanged, including every fail-closed
path from #7251 and #7401. A non-object element has no properties, so a
nested value of the wrong kind reports `missing field '<first field>'`, which
is what re-parsing its raw text reported. Malformed and empty bodies still
return the parser's `Err`. `json_generate_tests.l` pins the exact messages,
and passes unchanged against the pre-change compiler on dotnet (minus the one
case that calls `fromJsonElement` directly).

## String readers

`lyricJsonGetInt`/`Long`/`Double`/`Bool`/`String`/`SubObject` stay in
`Std.Json`. The self-hosted synthesiser never called them (only the retired
F# bootstrap did); `Std.Rest`'s one-field readers (`RestClient.jsonString`,
`jsonInt`, `jsonBool`) use them, and they are public, so external code may as
well. Their comment no longer claims the synthesiser uses them.

The JVM kernel's `lyricJsonGet{Int,Long,Double,Bool,String}Slice` are
removed. They lived only in `_kernel_jvm/json_host.l` (the .NET kernel dropped
its copies), nothing called them, `Std.JsonHost` is internal to `Std.Json`,
and they did not fail closed: `hostParseJson` panicked on a malformed body and
wrong-kind elements were skipped silently.

## JVM

A call to a derive-synthesised function was registered only under its
qualified key (`<owner>/<Type>.<fn>`), so the static `Type.fn(...)` call path
did not find it and typed the call as void. In tail position the value was
still returned by accident; in a value-producing `if` or `match` arm the join
saw mismatched stack depths (`stackmap simulation depth mismatch`), which is
one reason a nested `@generate(Json)` record never compiled for the JVM.
`collectDeriveFreeSigs` now registers the same keys `collectFileSigs` gives a
hand-written dot-named function (qualified, arity-suffixed, package-scoped,
and bare when `pub`/`internal`).

`fromJsonElement`'s parameter is written `Std.JsonHost.JsonElement`, the
declaring package of the type `Std.Json` hands out. A bare `JsonElement`
would bind to a user type of that name, and the JVM backend resolves a bare
type only through a file's direct imports, which `Std.JsonHost` never is
(the #7357 gap `lyric-i18n` worked around); a package-qualified type resolves
on both targets today.

One gap outside this change still stops nested records on the JVM. The JVM
backend emits a type-associated function `T.f` as a static method named `f`
on the package class, so two records' `fromJson(String)` (and now
`fromJsonElement(JsonElement)`) get the same name and descriptor and the
class fails to load (`ClassFormatError: Duplicate method name`). Any package
with two `@generate(Json)` records already failed this way before this
change, and nesting needs two records, so `json_generate_tests.l` runs on
dotnet only until the JVM method names carry the type (#7501). A package with one
`@generate(Json)` record decodes on the JVM as before (`json_tests.l`).

A call from one package to another package's derive-synthesised function
(`Person.fromJson(...)` with `Person` imported) also fails JVM codegen
(`auto-FFI: class 'Xp.Api.Person' not found`), before and after this change:
only the compiled package's own synthesised signatures are registered (#7502).

## Native

`--target native` has no `Std.Json` kernel (`lyric-stdlib/std/_kernel_native/`
has no `json_host.l`), so `@generate(Json)` is not available there and nothing
changes for it.
