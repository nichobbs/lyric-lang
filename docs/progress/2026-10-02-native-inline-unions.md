# Inline unions on `--target native` (docs/67 §4.2, G1 #7940)

A union whose every case payload field is by-value now lowers on
`--target native` to a tagged struct value `{ i32 disc, i32 pad, [W x i64]
payload }`: no heap allocation, no ARC header, no retain/release and no
destructor. `Option[Int]`, `Option[Vec3]`, `Result[Int, Int]`, enums with scalar
payloads and nullary cases (`None`, `Dot`) are now allocation-free. The language
is unchanged; this is the second half of the codegen policy D157 permits, after
by-value records (`2026-10-02-native-by-value-records`).

## What is inline

Decided in `Lyric.LlvmCodegen` next to the record classification
(`classifyInlineUnion`, same `lookupHeapType` precedence). A non-generic union is
inline when it is not an `impl` target and every payload field is a scalar, an
enum, a distinct type over one, a by-value record, or another inline union. A
union that holds itself, directly or through another union, stays heap. A
generic union classifies per instantiation (`genericUnionInline`): `Option[Int]`
and `Option[Vec3]` inline, `Option[String]` and a recursive instantiation heap.
By-value records may now hold non-generic inline unions as fields.

## Lowering

- `NUnionInfo` has an `inline` flag; `unionPtrType` is the header-less struct
  for an inline union. Layout (payload words, C alignment) comes from the same
  size rules as records, computed before any registry exists for non-generic
  unions (`stSizeOf`/`stAlignOf`).
- Construction builds the value in a hoisted stack slot and loads it; nullary
  cases no longer allocate per use. Matching and payload reads address a stack
  copy (`inlineUnionAddr`) and reuse the pointer-based discriminant and payload
  GEPs with inline slot indices (`unionDiscIdx`, `unionPayloadIdx`).
- Equality compares case then payload fields, through the synthesised
  per-union function on stack copies; `synthUnionEq` owns its function-level
  slots.
- List/Map/Task slots box an inline union in the `__box<U>` the by-value records
  use. `isRefNType` is false for the value and for a raw pointer to it (header
  check), so ARC never touches either.
- An inline union in an `extern func` signature is rejected as `N0010`
  (#8009), as for by-value records.

## Generic applications in field types

A record or union field written as a generic application (`o: Option[Vec3]`,
`case Got(o: Option[Int])`) is classified by resolving the generic declaration
like codegen does (generic unions, then generic records, by the written name then
the bare one), substituting the by-value arguments, and applying the same
per-instantiation rule (`classifyGenericUnionInst` / `classifyGenericRecordInst`).
The instantiation is registered with its layout and instantiation metadata
before any layout, so codegen's lazy instantiation finds it and both agree by
construction. A generic record whose instantiation is all by-value is by-value
too (`Box[Int]` nested in another record). Classification runs once over the
whole bundle, so a multi-package build classifies exactly as a single-package one
(native has no separate compilation).

## Equality

`synthUnionEq` has no same-instance shortcut, so equality is structural (IEEE)
for heap and inline unions alike: `x == x` with a NaN payload is false on native
for both. On dotnet and jvm it is true for both forms (the host's `Equals`
treats NaN as equal to itself) -- a pre-existing cross-target difference in
union equality, not changed here.

## Left heap, with reasons

- Unions with a reference payload (String, List, heap record, closure) and
  recursive unions: the payload needs ARC or indirection.
- Unions that are `impl` targets: interface boxing of values is #8010 (native
  has no `impl` for unions at all today).

## Verification

`llvm_inline_union_self_test.l` (ASan plus `.ll` assertions: no `lyric_alloc`,
heap form kept where required, alignment, nesting, equality, List/Map boxing,
generic applications in fields, closures, async, raw pointers, wasm32 layout,
NaN equality, bundles, `N0010` including a generic union in an extern signature
through the real build) and `inline_union_self_test.l` (the whole
pipeline: `?` over `Option`/`Result`, structural `==`, collections, closures, on
dotnet, jvm and native). Both are in the native CI list.
