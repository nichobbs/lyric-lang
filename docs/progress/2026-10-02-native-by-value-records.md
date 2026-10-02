# By-value records on `--target native` (docs/67 §4.2, G1 #7940)

A record with no `var` field whose fields are all by-value now lowers on
`--target native` to a plain LLVM struct value: no heap allocation, no ARC
header, no retain/release and no destructor. A `Vec3` built from field reads
and a constructor call, which is what `@derive(Add, Sub)` lowers to in the
shared pipeline, no longer allocates. The language is unchanged; this is a
codegen policy (D157 item 1 permits it).

## What is by-value

Decided once per record declaration in `Lyric.LlvmCodegen`
(`classifyByValueRecords`, run before any layout), so every other type mapping
agrees. A record is by-value when it has no `var` field, at least one field,
no generic parameters, is not an `opaque type`, is not the target of any
`impl I for R`, and every field is a scalar (`Bool`, `Byte`, `Char`, `Int`,
`Long`, `Float`, `Double`), an enum, a distinct type over one of those, or
another by-value record. A generic record is classified per instantiation by
its concrete field types (`Box[Int]` and `Box[Vec3]` are by-value,
`Box[String]` is not). A raw `NativePtr` to a by-value record is not an ARC reference
(`isRefNType` recognises heap objects by their ARC header).
Everything else keeps the shared heap form, in
particular every record with a `var` field (D157). Unions stay heap.

## Lowering

- The record's type is the header-less named struct itself, never behind a
  pointer (`recPtrType` returns the struct for a by-value `NRecInfo`).
- `Lyric.LlvmIr` gains `NInsertValue` and `NExtractValue`. Construction is an
  `insertvalue` chain from `undef`; a field read is `extractvalue`, also when
  the struct was first loaded out of a heap record's field or a union payload.
- `sizeOfN`/`alignOfN` size a struct value with C rules, so unions hold one.
- A by-value record stored in a `List`, `Map` value or `Task` slot is boxed in
  a refcounted `__box<R>` (header plus struct, no destructor); reads copy the
  struct back out. A by-value record is rejected as a `Map` key.
- `==` on two struct values (union payload equality, or an unrewritten generic
  site) compares field by field.
- An `extern func` signature naming a by-value record is rejected as `N0010`
  (before codegen, with a codegen backstop): an LLVM aggregate is not the
  platform C struct ABI (callback types included). The C ABI for by-value
  struct arguments and returns (System V AMD64, AAPCS64) is #8009; boxing a
  by-value record at an interface upcast is #8010. No existing
  kernel or example passes a record to C by value.

## Verification

`llvm_byvalue_record_self_test.l` (ASan, plus assertions on the emitted `.ll`:
no `lyric_alloc`, no ARC call, no destructor, `insertvalue`/`extractvalue`,
heap form kept for `var` fields, interface implementers, opaque types and
reference fields) and `byvalue_record_self_test.l` (the whole pipeline: derived
`Add`/`Sub`, structural `==`, `.copy`, collections, closures, generics, on
dotnet, jvm and native). Both are in the native CI list.
