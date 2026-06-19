# 42 — Metadata-based extern signature resolution

_Status: **Design (Phase 0 of epic #1622)**, drafted 2026-05-30 on branch
`claude/epic-1622-l4hd3`. Backs epic #1622 (Band 4 of #1470, spun out of
#1504 H9). Unbacked by a decision-log entry until Phase 1 lands; this doc is
the source-of-truth design for the metadata-resolution slice and will carry
the backing entry id once codified._

_This is a design + phased-delivery plan for an epic-sized subsystem. All
file:line citations and empirical findings are to the working branch at draft
time, gathered by reading the source and running probes against the built
self-hosted `lyric` binary, not by trusting prior docs._

---

## §1  Executive summary

The self-hosted `--target dotnet` MSIL emitter does **not** resolve external
method signatures from .NET metadata. Two lossy mechanisms stand in for it:

1. **`@externTarget` path** — the MemberRef signature is transcribed from the
   *declared Lyric function signature* the author writes. Correct only if the
   author hand-transcribes the BCL signature faithfully; nothing verifies the
   transcription against the real method.
2. **Auto-FFI path** (`ExternTypeName.method(args)`, no wrapper) — emits a
   fixed `(object…) : void` MemberRef (`emitAutoFfiCallMsil`,
   `codegen.l:6588`). Correct only for static, void-returning, all-`object`-
   parameter methods; everything else mis-binds at runtime. #1504 H9 gates the
   unfaithful shapes behind a loud diagnostic as a stopgap.

The assembly that hosts each type is guessed from a hardcoded prefix table
(`clrAssemblyForType`, `ffi.l:124`), with `System.Runtime` as the long-tail
default.

This is a regression from the F# bootstrap emitter, which does real reflection
(`Codegen.fs` `ClrType`/`GetMethod` with overload resolution — `Math.Min(2,5)`
coerces `Int`→`Long`, `Path.Combine(string,string)` binds the right overload;
both pass in `AutoFfiTests.fs`). The self-hosted path can't reuse that because
it emits raw PE bytes (no `PersistedAssemblyBuilder`, so no live `System.Type`),
and runtime `System.Type.GetType` returns null from Lyric-emitted PEs
(D-progress-268).

**The decision this doc reaches:** resolve signatures with a **pure-Lyric
CLI-metadata reader** that reads reference-assembly bytes off disk (via
`Std.File`) and parses the ECMA-335 metadata directly — *not* via
`System.Reflection.Metadata` (struct-heavy, FFI-hostile) and *not* via
`System.Reflection.MetadataLoadContext` (unavailable; NuGet-only). This
inverts the metadata *writer* the emitter already ships in pure Lyric
(`pe.l`/`tables.l`/`heaps.l`), is BCL-dependency-free and AOT-clean, and
sidesteps the D-progress-268 blocker by construction (no runtime type loading
ever occurs — it is pure byte reading).

---

## §2  The D-progress-268 blocker, investigated

D-progress-268 documents that the self-hosted FFI abandoned reflection because
`System.Type.GetType` "consistently returns null even for types demonstrably
loaded" from Lyric-emitted code, and fell back to the hardcoded
`clrAssemblyForType` table + declared signatures.

**Finding (high confidence): the blocker is specific to *runtime reflection
that resolves types against the emitting/calling assembly*, not to reading
metadata bytes off disk.** `Type.GetType(string)` walks the runtime's loaded
assemblies and the *caller's* assembly metadata to bind a name; a Lyric-emitted
PE's calling-assembly metadata is what trips it. A reader that opens a
reference-assembly *file* and parses its tables never invokes that path — it
loads no type into the runtime and consults no calling-assembly metadata. The
issue's own hypothesis ("`MetadataReader` is a pure byte reader, not a runtime
type loader") is correct, and a hand-rolled reader is *even more* purely a byte
reader. **D-progress-268 does not block metadata reading.**

### What was empirically verified at draft time

Against the built self-hosted `bin/lyric` (stage-1 + AOT):

- The reference-assembly pack is present and discoverable at
  `$DOTNET_ROOT/packs/Microsoft.NETCore.App.Ref/10.0.7/ref/net10.0/`
  (167 ref DLLs incl. `System.Runtime.dll`).
- `System.Reflection.Metadata.dll` ships in both the ref pack and the shared
  runtime — so the struct API *is* available in the BCL.
- `System.Reflection.MetadataLoadContext.dll` is **absent** from the ref pack,
  the shared runtime, and the NuGet cache — it is a separate NuGet package.

### A real dependency blocker surfaced by the probe

A probe that calls `Std.File.readBytes(path)` on the self-hosted runtime throws
`System.MissingMethodException: Method not found: 'Std.Core.Result<...>
Std.File.Program.readBytes(System.String)'`, while a non-generic-return stdlib
call (`Std.File.fileExists`) links and runs fine. **Cross-assembly stdlib
functions whose return type is a generic (`Result[List[Byte], IOError]`) do not
currently link on the self-hosted runtime** — this is Band-0 / #1471
("cross-package generic-arg widening") territory.

Consequence for this epic: **the metadata reader reads bytes through a
non-generic-return entry point, not through `Std.File.readBytes`.** The kernel
primitive `Std.FileHost.hostReadAllBytes(path): slice[Byte]`
(`@externTarget("System.IO.File.ReadAllBytes")`,
`lyric-stdlib/std/_kernel/file_host.l:53`) already exists and panics on I/O
error per the kernel's established no-`Result`-across-FFI convention. Phase 1
exposes a thin `pub func readBytesOrPanic(path): slice[Byte]` on `Std.File`
over it (keeping `_kernel` private to `Std.File` per the kernel-boundary rule;
shipped in `file.l`), and the reader imports that.

**Caveat (honest status).** This avoids the generic-`Result` shape, but it does
**not** by itself prove the self-hosted *runtime* resolves the cross-package
call: a standalone consumer built with `bin/lyric` and run against the prebuilt
stdlib DLLs still raised `MissingMethodException` for both `readBytes` (generic)
and `readBytesOrPanic` (array `Byte[]`) — in the latter case at least partly
because the per-package `Lyric.Stdlib.File.dll` next to the AOT binary was stale
(predated the new method), but the original `readBytes` failure (the method was
present in the shipped bundle) indicates a genuine #1471-family cross-package
resolution gap for non-primitive return shapes. **Phase 1 is therefore gated on
the bootstrap-emitter self-test** (`lyric-stdlib/tests/metadata_reader_tests.l`,
auto-discovered by `StdlibLyricTests.fs`), which compiles and runs the reader
end-to-end against a real PE and passes. The self-hosted *runtime* path
(needed when the reader is wired into codegen at Phase 3) must have the
#1471-family cross-package resolution green first; when wired, the reader runs
*inside* the compiler bundle where in-bundle cross-package token resolution
(#1470 Band 4) applies, which is a different resolution path than the
standalone-consumer probe. Tracking this dependency explicitly is the Phase 3
entry criterion.

---

## §3  Why a pure-Lyric reader, not the BCL metadata APIs

Three candidate mechanisms; the choice is forced by Lyric's FFI capabilities.

### Option A — `System.Reflection.Metadata` (`PEReader` + `MetadataReader`)

In the BCL (no new dependency). **Rejected as the primary mechanism** because
the API is value-type-heavy: `MetadataReader` and `BlobReader` are
`readonly struct`s, and every handle (`TypeDefinitionHandle`,
`MethodDefinitionHandle`, `BlobHandle`, …) and row view (`TypeDefinition`,
`MethodDefinition`, `Parameter`) is a struct returned by value. Lyric's
`extern type` maps to `ELEMENT_TYPE_CLASS` + a `TypeRef` (a reference type):
**there is no value-type extern support today.** Every extern type in
`lyric-stdlib/std/_kernel/*.l` is a reference type, and
`assembly_resources_host.l`'s author explicitly rejected the `BlobReader`
value-type path as needing "either unsafe pointer arithmetic (Lyric doesn't
expose unsafe pointers) or a ~12-extern chain through the `BlobReader`
value-type API." Calling an instance method on a struct also requires a managed
pointer (`ldloca` + `call`), which the FFI codegen does not emit. Adopting this
API means first building value-type FFI into the emitter — a large codegen
feature in its own right, and a permanent runtime dependency on the struct API.

### Option B — `System.Reflection.MetadataLoadContext`

The FFI-friendly choice (reference-type reflection API: `Assembly`, `Type`,
`MethodInfo`, `ParameterInfo` are all classes), and it is inspection-only so it
sidesteps D-progress-268 the same way. **Rejected** because it is **not
available**: it ships only as the `System.Reflection.MetadataLoadContext` NuGet
package, absent from the runtime/ref pack and the offline NuGet cache. Pulling
it in adds a network-restore dependency (the environment's network policy may
forbid it), a new entry on the compiler's runtime closure, and a NativeAOT
trim/reflection risk that directly conflicts with Band 5 (#1494 AOT-clean
binary).

### Option C — pure-Lyric CLI-metadata reader (chosen)

Read the reference assembly's bytes and parse ECMA-335 metadata directly in
Lyric. **Chosen** because:

- **BCL-dependency-free and AOT-clean** — only `Std.File` byte reading +
  arithmetic; nothing for NativeAOT to trim or fail to resolve.
- **Sidesteps D-progress-268 by construction** — no runtime type loading at
  all.
- **Inverts machinery the emitter already ships in pure Lyric.** The MSIL
  emitter *writes* exactly these structures: `heaps.l` builds
  `#Strings`/`#Blob`/`#US`/`#GUID`; `tables.l` builds TypeRef/TypeDef/Field/
  MethodDef/Param/MemberRef/AssemblyRef rows with the coded-index encoders
  (`tdrTypeDef`, `mrpTypeRef`, …) and compressed-integer writers; `pe.l`
  writes the PE/COFF/optional headers and the CLI data directory. A reader
  reuses the same row record shapes, coded-index *decoders* (inverse of the
  encoders), compressed-integer *readers* (inverse of
  `writeCompressedUInt`), and signature-blob *decoder* (inverse of
  `bufMsilType`).
- **Matches established codebase philosophy.** `lyric-proto` (protobuf wire
  decoder), `Std.Xml`, and `Std.Yaml` are all pure-Lyric binary/text parsers;
  the emitter itself is a pure-Lyric PE *writer*. A pure-Lyric PE *reader* is
  squarely in line.

The cost is implementing a metadata reader from scratch — but the table/heap
model, coded-index scheme, and signature grammar are already encoded in
`tables.l`/`heaps.l`/`lowering.l`, so most of the hard modelling is done and
the work is "invert the existing writers."

---

## §4  Architecture

A new pure-Lyric library, `Msil.MetadataReader` (under `lyric-compiler/msil/`,
in the reserved `Msil.*` namespace alongside `Msil.Ffi`), exposing a
**high-level composing entry point** that integration sites call, plus the
lower-level per-assembly query it composes:

```
// High-level: discovery + resolution in one call. This is what the auto-FFI
// and @externTarget integration sites use — the caller supplies only the type
// FQN, member, and arg types; the reader internally consults the cached
// type-FQN → owning-assembly index (see "Assembly discovery" below) to find
// the assembly, then resolves the method. Returns None only when the type or
// a matching overload is genuinely absent (callers turn None into a
// diagnostic — see §6).
resolveExtern(
  ctx:       CodegenCtx,       // carries the memoized discovery index + caches
  typeFqn:   String,           // "System.Math"
  member:    String,           // "Min" | ".ctor"
  argTypes:  List[MsilType]    // lowered Lyric arg types, for overload scoring
): Option[ResolvedExtern]

// Implementation note: `Msil.MetadataReader` cannot `import Msil.Codegen`
// to consume the full `CodegenCtx` (a cycle — codegen imports the reader),
// so the reader-facing surface uses a narrower `MetadataReaderCtx` record
// defined inside `Msil.MetadataReader` itself (assembly-path → parsed-index
// map; ref-pack dir).  `CodegenCtx` embeds one and `resolveExtern` projects
// it on entry; in spec-level pseudocode the `ctx: CodegenCtx` form reads
// naturally, but the package boundary is the projected sub-record.

record ResolvedExtern {
  assemblyName: String         // owning assembly's simple name (for the AssemblyRef row)
  sig:          ResolvedSig
}

// Lower-level: resolve within one already-located assembly file. resolveExtern
// composes refPackDir()/the index + this. Exposed for testing and for callers
// that already know the assembly (e.g. a restored dependency DLL).
resolveMethod(
  asmPath:   String,          // resolved reference-assembly file
  typeFqn:   String,          // "System.Math"
  member:    String,          // "Min" | ".ctor"
  argTypes:  List[MsilType]   // lowered Lyric arg types, for overload scoring
): Option[ResolvedSig]

record ResolvedSig {
  paramTypes: List[MsilType]
  returnType: MsilType
  isStatic:   Bool
  isVirtual:  Bool            // HASTHIS + virtual flag → callvirt vs call
  // (generic methods → MethodSpec; see Phase 4)
}
```

### Layers (each a self-contained, testable unit)

1. **PE container reader** — given the file bytes, parse the DOS stub
   (`e_lfanew` @ 0x3C), PE signature, COFF header, optional header (PE32/PE32+),
   section headers, and the CLI header from data-directory entry 14; map RVAs
   to file offsets via the section table; locate the metadata root. *Inverts
   `pe.l`.*
2. **Metadata-root + stream reader** — parse the `BSJB` metadata root, the
   stream headers (`#~`, `#Strings`, `#US`, `#GUID`, `#Blob`), and the `#~`
   table-stream header (heap-size flags → 2-vs-4-byte index widths, the valid-
   table bitvector, per-table row counts). *Inverts the layout logic in `pe.l`/
   `tables.l`.*
3. **Heap readers** — `#Strings` (null-terminated UTF-8 at a byte offset),
   `#Blob` (compressed-length-prefixed). *Inverts `heaps.l`.*
4. **Table row readers** — compute each table's row size from the column
   schema + index widths, then read TypeDef (0x02), MethodDef (0x06), and Param
   (0x08) rows; resolve the implicit `fieldList`/`methodList`/`paramList`
   run-length ownership the writer encodes (`tables.l:182`). *Inverts the row
   records in `tables.l`.*
5. **Signature-blob decoder** — decode a MethodDefSig blob (calling convention
   incl. HASTHIS/GENERIC, generic-param count, param count, return type, param
   types) into `MsilType`s. *Inverts `bufMsilType` in `lowering.l`.*
6. **Overload resolution** — among MethodDef rows of `typeFqn` named `member`,
   pick the best match for `argTypes`, replicating the F# emitter's coercion
   rules (exact match > widening numeric conversion, e.g. `Int`→`Long`; see
   `Codegen.fs` `closeBclMethod`/overload scoring and `AutoFfiTests.fs`).

### Assembly discovery (replaces `clrAssemblyForType`)

A `refPackDir()` resolver locates
`$DOTNET_ROOT/packs/Microsoft.NETCore.App.Ref/<ver>/ref/<tfm>/` (honoring
`DOTNET_ROOT`/`LYRIC_*` env and the AOT trampoline's environment), enumerates
the ref DLLs once, and builds a **type-FQN → owning-assembly index** by reading
each assembly's TypeDef table (and ExportedType/type-forward rows, since e.g.
`System.Math` lives in `System.Private.CoreLib` but is type-forwarded through
`System.Runtime`). The hardcoded `clrAssemblyForType` prefix table is then
deleted, replaced by this metadata-derived, cached index. Restored dependency
DLLs (already located by `restored_packages.l`) feed the same index so
dependency externs resolve identically.

### Integration points

- **Auto-FFI** (`emitAutoFfiCallMsil`, `codegen.l:6564`): replace the
  `(object…) : void` stub with `resolveExtern(ctx, typeFqn, member, argTypes)`
  → real assembly + param/return/`this` shape; intern the AssemblyRef/TypeRef
  from `assemblyName`; emit `call` vs `callvirt` from `isVirtual`/`isStatic`;
  box/coerce args per the resolved param types. The call site needs no prior
  knowledge of the owning assembly — `resolveExtern` discovers it.
  **Removes the #1504 H9 guess entirely.**
- **`@externTarget`** (`lowerFuncMsil` FFI branch + `Msil.Ffi`): resolve from
  metadata via `resolveExtern`, then *check* the author's declared Lyric
  signature against it; on disagreement emit a clear diagnostic (**F0015**,
  reserved here — next free in the F-series after F0014; confirm against the
  diagnostic registry at implementation time and update the catalogue in
  `docs/09-msil-emission.md`) rather than silently trusting the transcription.
  The declared signature becomes a verified redundancy, not the source of
  truth.
- **Generic methods**: route through the MethodSpec table (#1497, shipped); the
  signature decoder must handle `MVAR`/`VAR` and the GENERIC calling
  convention.

### Caching

Per-assembly: parse the container + heaps + the type/method indices **once**
per build and memoize on `CodegenCtx`, keyed by assembly path. Per-call lookups
then hit an in-memory index, so metadata reading does not dominate build time.
This mirrors the existing lazy `ffiAsmRefs`/`ffiTypeRefs` caches
(D-progress-268).

---

## §5  Phased delivery

Each phase is independently shippable and testable via the
`*_self_test.l` mechanism (run by the Emitter test suite), using **in-memory
byte arrays** for the parser layers so tests don't depend on the `readBytes`
runtime gap.

- **Phase 1 — byte-read foundation + PE/metadata-root reader. _(SHIPPED.)_**
  `Std.File.readBytesOrPanic(path): slice[Byte]` added over the existing
  `hostReadAllBytes` kernel extern. `Msil.MetadataReader`
  (`lyric-compiler/msil/metadata_reader.l`) implements layers 1–2: the PE
  container (DOS/PE/COFF/optional header PE32+PE32+, section table,
  `rvaToOffset`, CLI header) → metadata root (`BSJB`, version string, stream
  headers, `findStream`) → the `#~`/`#-` table-stream header (heap-index
  widths, the valid bitvector read byte-wise, per-table row counts,
  `rowCountOf`). Self-tested by `lyric-stdlib/tests/metadata_reader_tests.l`,
  which parses the running test PE itself (a real assembly emitted by the
  compiler's own writer — a reader-vs-writer oracle needing no version-specific
  ref-pack path) and asserts the container, RVA mapping, stream set, and
  Module/TypeDef/MethodDef row counts. Compiles cleanly through both the
  bootstrap and self-hosted emitters. *No emitter behaviour change yet.*
- **Phase 2a — heaps + table rows. _(SHIPPED.)_** Layers 3–4: the compressed-
  integer reader (inverse of `writeCompressedUInt`), the `#Strings` (UTF-8) and
  `#Blob` (length-prefixed) heap readers, the table layout computation
  (heap-index and coded-index column widths, per-table row sizes, table data
  offsets), and the TypeDef/MethodDef/Param row readers with run-length
  method-list ownership (`methodRange`). The self-test extends the running-PE
  oracle: it reads the test assembly's real tables and asserts the `Program`
  TypeDef, its `main` method, `<Module>` at row 1, and non-empty MethodDefSig
  blobs.
- **Phase 2b — signature-blob decoder. _(SHIPPED.)_** Layer 5: `decodeMethodSig`
  decodes a MethodDefSig blob (calling convention incl. HASTHIS/GENERIC,
  generic-param count, param count, return + param types) into a `SigType` over
  the full ECMA element-type grammar — primitives, CLASS/VALUETYPE tokens,
  VAR/MVAR, SZARRAY/ARRAY, BYREF/PTR, GENERICINST, custom-modifier skipping,
  vararg SENTINEL, and nested FNPTR sigs. Self-tested both as the inverse of
  the emitter's `buildStaticMethodSig`/`buildInstanceMethodSig` + `bufMsilType`
  (hand-built blobs → expected `SigType`) and as a running-PE oracle (every
  MethodDefSig in the test assembly decodes; `main` → static, parameterless).
- **Phase 3a — reference-assembly discovery + type→assembly index. _(SHIPPED.)_**
  `refPackDir()` locates `<root>/packs/Microsoft.NETCore.App.Ref/<ver>/ref/<tfm>/`
  (probing `DOTNET_ROOT`, `$HOME/.dotnet`, and the system install roots);
  `enumRefAssemblies` lists the ref DLLs; `buildTypeIndex` reads each
  assembly's TypeDef table and maps every public type's FQN to its assembly's
  simple name; `assemblyForType` looks one up. In the .NET ref pack the BCL
  types are real TypeDefs in their facade assembly (`System.Math` →
  `System.Runtime`, `System.Console` → `System.Console`; verified empirically),
  so a TypeDef-derived index needs no ExportedType/type-forward chasing.
  Self-tested hermetically (the running test DLL's own `Program` type) and
  against the real ref pack (`System.Object`/`System.Math` → `System.Runtime`).
- **Phase 3b — overload resolution. _(SHIPPED.)_** Resolution works in
  `SigType` space (decoupled from `MsilType`; the caller maps its lowered
  argument types to `SigType`s at the call boundary): `findTypeDefByFqn` locates
  the type, `resolveOverloadIn` decodes each same-named MethodDef's signature
  and scores it with `scoreOverload`/`scoreSigType` — exact match (2) beats a
  widening numeric conversion (1, via a `numericRank` ladder, e.g. `Int`→`Long`),
  an `object` parameter accepts any argument, and arity/type mismatches reject
  (−1) — returning a `ResolvedMethod` (`isStatic`/`isVirtual` + decoded
  return/param types). Self-tested hermetically (`addInts(Int, Int)` over the
  running PE: exact, widening `I2`→`I4`, arity-mismatch and unknown-member/type
  rejection) and against real BCL overloads (`System.Math.Max` binds the `int`
  overload for `(Int, Int)` and the `long` overload for `(Long, Long)`).
- **Phase 3c (step 1) — wire metadata resolution into `emitAutoFfiCallMsil`.
  _(SHIPPED.)_** `codegen.l` now imports `Msil.MetadataReader` and, on an
  auto-FFI call (`ExternTypeName.method(args)`), lowers each argument into its
  own buffer to capture its `MsilType`, maps those to `SigType`s
  (`Mdr.mkPrimSig`), and calls `Mdr.resolveOverload` against the assembly the
  existing `clrAssemblyForType` hint names. On an exact-match **static** method
  whose parameter/return types are primitive/string/object, it builds the real
  MemberRef (`buildStaticMethodSig` over the resolved `MsilType`s) and emits
  `MCall`, returning the true result type — **removing the #1504 H9
  argument-bearing guess for these calls**. Anything else (mis-hinted assembly,
  numeric coercion, instance methods, class/valuetype params) falls back to the
  legacy `@externTarget` path unchanged (no regression).

  **The key validation:** the reader runs *in-bundle* at compile time — the
  self-hosted compiler reads the reference pack while compiling a user program.
  `extern type Math = "System.Math"; Math.Max(2, 5)` resolves to
  `Math.Max(int, int) : int` and runs (→ 5); covered in CI by
  `lyric-compiler/lyric/auto_ffi_self_test.l` (native `lyric test`). The
  standalone-consumer `T0010`/`T0020`/`MissingMethodException` failures in §2 do
  **not** apply here, confirming the in-bundle resolution path the §2 caveat
  anticipated.

  Cross-package note: `codegen.l` imports the reader **aliased** (`as Mdr`)
  because the reader's `TypeDefRow`/`MethodDefRow`/… record names collide with
  the writer's; since the bootstrap parser rejects *package-qualified union-case
  patterns* (`case Mdr.STPrim(b)`), `Msil.MetadataReader` exposes `mkPrimSig` /
  `sigPrimByte` accessors so codegen never matches or constructs an imported
  union case directly.
- **Phase 3c (step 2a) — full-index resolution. _(SHIPPED.)_** `emitAutoFfiCallMsil`
  no longer takes the assembly from the `clrAssemblyForType` hint; it builds the
  metadata-derived type→assembly and assembly→path indexes once over the
  reference pack (`ensureMetadataIndex`, cached on `CodegenCtx` via a one-shot
  `metadataReady` flag and `Mdr.addAssemblyToIndexes`), then resolves with
  `Mdr.resolveExtern`. Types the hint table mis-named — e.g. `System.IO.Path`,
  which it sent to `System.IO.FileSystem` but actually lives in `System.Runtime`
  — now resolve, so `Path.Combine("/tmp", "x.txt")` works where step 1 fell back
  to `@externTarget`. Covered by `auto_ffi_self_test.l`.
- **Phase 3c (step 2b) — numeric coercion + box. _(SHIPPED.)_** `emitResolvedAutoFfi`
  no longer requires an exact parameter match: per argument it computes a
  coercion (`argCoercionInsns`) and emits it after the argument — empty for an
  exact match, `conv.i8`/`conv.r8` for a widening numeric conversion (so an
  `Int`/`Long` argument binds a `(long)`/`(double)` overload), or `box` for an
  `object` parameter. The MemberRef is still built from the resolved parameter
  types. Covered by `auto_ffi_self_test.l` (`Math.Sqrt(4)` / `Sqrt(9i64)` widen
  to the `(double)` overload). Remaining fallbacks: class/value-type parameters,
  and `→float`/narrowing conversions. (Instance methods are N/A for auto-FFI —
  the receiver is a type name — so they stay `@externTarget`-only.) Checking
  `@externTarget` declared signatures against metadata moves to Phase 4.
- **Phase 3c (step 3) — value-type parameters & returns. _(SHIPPED.)_** Two
  pieces.  First, the reader resolves non-primitive types by **FQN, not token**:
  `readTypeRef` + `resolveTypeDefOrRefName` turn a `CLASS`/`VALUETYPE`
  TypeDefOrRef token into a type name, and `resolveOverloadIn` normalises each
  candidate's parameter/return `SigType` into `STNamed(fqn, isValueType)` before
  scoring — so a caller's value-type argument (described by FQN) matches a
  parameter whose token lives in a *different* assembly's metadata.  Second,
  codegen maps a resolved value type to `MValueTypeRef` (`internValueTypeRef`,
  whose `bufMsilType` encoding is `VALUETYPE + TypeRef`), passes a value-type
  argument by FQN (`argTyToSig`), and the MemberRef-key fragment encodes each
  type's identity (`sigTypeKeyFrag`).  End-to-end:
  `TimeSpan.Compare(TimeSpan.FromMinutes(5.0), TimeSpan.FromMinutes(3.0)) == 1`
  — a value-type return feeding value-type parameters, resolved entirely from
  metadata.
- **Phase 3c (step 4a) — class (reference-type) parameters & returns.
  _(SHIPPED.)_** The reference-type counterpart of step 3.  A new `MClassRef(
  typeRefCode, clrFqn)` MsilType carries a pre-interned TypeRef so a method
  signature encodes `CLASS + TypeRef` (a MemberRef whose return/param said
  `object` would fail to bind to a method that really returns the class —
  `MissingMethodException`).  `internClassRef` builds it; `resolvedSigToMsil`
  maps a resolved class `STNamed` to it; `argTyToSig` / `externRefFqn` describe
  a class-ref argument by FQN; `argCoercionInsns` matches a class argument to a
  class parameter by FQN (and a class argument still satisfies an `object`
  parameter with no box, since it is already a reference).  In local-variable
  signatures `MClassRef` degrades to `object` (safe — it is a reference).
  End-to-end:
  `Object.ReferenceEquals(Type.GetType("System.Int32"), Type.GetType("System.Int32"))`
  is `true` — `Type.GetType(string): Type` returns a real, usable class
  reference resolved from metadata.  Instance-method dispatch (step 4b) builds
  directly on this: a class return is the receiver a `callvirt` dispatches on.
- **Phase 3c (step 4b) — instance-method dispatch. _(SHIPPED.)_** The marquee
  end-to-end path.  `lowerMethodCallMsil` now detects an extern class-ref
  receiver (`MClassRef`) — produced by a class-returning static or any
  class-typed extern expression — and routes `recv.method(args)` through
  `tryInstanceAutoFfiFromMetadata`: it resolves the *instance* method from
  metadata (`resolveOverloadIn` already reports `isStatic = not sig.hasThis`),
  builds a HASTHIS MethodSig (`buildInstanceMethodSig`), and emits `callvirt`
  against the real CLR method (valid for both virtual and non-virtual instance
  methods on a reference receiver).  Arguments are buffered before resolution so
  a failed lookup leaves the stack holding only the already-pushed receiver and
  the caller's legacy dispatch stays correct; a resolved *static* (no instance
  overload) also falls back rather than emit a malformed `callvirt`.  End-to-end:
  `Type.GetType("System.Int32").ToString() == "System.Int32"` — a class-returning
  static feeds a receiver-based instance call, both resolved entirely from
  metadata.  Value-type instance methods (which need `ldloca` + `call` on a
  managed pointer rather than `callvirt`) remain a follow-up.
- **Phase 4 — `@externTarget` verification + `clrAssemblyForType` removal +
  generics. _(SHIPPED — D-progress-485.)_** `emitExternTargetBody` in
  `codegen.l` now verifies the declared Lyric signature against reference-assembly
  metadata before emitting the MemberRef (diagnostic **F0015** on mismatch).
  `ensureMetadataIndex` was extended to add all restored-dependency DLL paths to
  the type and path indexes so that types from NuGet-restored Lyric packages are
  included in the metadata-grounded assembly check.  The `clrAssemblyForType`
  hardcoded table was already deleted in Phase 3a; the remaining prefix-based
  `clrAssemblyResolvable` guard is now demoted to a fallback after a metadata-index
  lookup so that NuGet types outside `System.*`/`Lyric.*` are accepted.  Full
  MethodSpec routing for generic `@externTarget` declarations is deferred to a
  follow-up — the verification block skips params whose `MsilType` has no
  `SigType` equivalent (sets `canVerify = false`), so generic externs compile
  without F0015 but remain unverified.  Tests in `auto_ffi_self_test.l` (`@externTarget
  with verified signatures compile and run correctly`).
- **Phase 5 — JVM parity. _(SHIPPED — D-progress-485.)_** `lowerExternTargetBody`
  in `jvm/codegen/04_calls.l` now performs the analogous metadata-based overload
  lookup via `Jvm.AutoFfi.loadClass` + `findBestMethod` / `findBestConstructor`
  immediately after computing the JVM arg and return types.  A mismatch emits
  **F0015-J** (panic with the descriptor signature and the target FQN).  Skipped
  when the class is absent from the JDK jmods / LYRIC_FFI_JARS index (non-JDK
  types with no configured JAR entry).  Tests in `auto_ffi_jvm_self_test.l`
  (`@externTarget with verified JVM signatures compile and run correctly`).

---

## §6  Diagnostics

User-visible, production-quality (no placeholder dumps):

- **Extern type / assembly not found in any reference assembly or restored
  dependency** — name the type, list where the reader looked (ref pack dir +
  restored DLLs). Supersedes the #1504 H8 `clrAssemblyResolvable` panic with a
  metadata-grounded message.
- **No overload of `Type.method` matches the argument types** — name the type,
  method, the supplied arg types, and the candidate signatures found in
  metadata.
- **`@externTarget` declared signature disagrees with metadata** (new,
  **F0015** — see §4) — show the declared vs the resolved
  `(paramTypes) → returnType`, and which differs.

---

## §7  Open questions

- **Q-MD-001** — _Resolved + shipped (Phase 1):_ `Std.File.readBytesOrPanic`
  (non-generic `slice[Byte]`) wraps the existing `hostReadAllBytes`, keeping
  `_kernel` private to `Std.File`. Remaining: the self-hosted *runtime*
  cross-package resolution of this call (#1471 family) must be green before the
  Phase 3 codegen wiring — see the §2 caveat. Until then the reader is gated on
  the bootstrap-emitter self-test.
- **Q-MD-002** — Ref-pack version/TFM selection when multiple packs are
  installed: pin to the SDK `global.json` runtime, or the
  highest-compatible? _Leaning: pin to the pinned runtime to match what the
  emitter's AssemblyRefs already target._
- **Q-MD-003** — Type-forward (ExportedType) chain depth: how many forward hops
  to follow before erroring (`System.Math` → `System.Runtime` →
  `System.Private.CoreLib`).
- **Q-MD-004** — Overload-resolution fidelity vs. the F# emitter: which
  coercion rules to replicate exactly (numeric widening, `params`, optional
  args, nullable) and which to defer with a diagnostic.
- **Q-MD-005** — _Resolved (Phase 5 — D-progress-485):_ `lowerExternTargetBody`
  in `jvm/codegen/04_calls.l` reuses the existing `Jvm.AutoFfi` class reader
  (which already reads `.class` files from JDK jmods / LYRIC_FFI_JARS) rather
  than adding a separate constant-pool reader.  The auto-FFI overload scorer
  (`findBestMethod` / `findBestConstructor`) doubles as the signature validator,
  consistent with the auto-FFI pipeline already shipping in Phase 3c JVM.

---

## §8  References

- Epic #1622; master plan #1470 (Band 4); #1504 (H8/H9 stopgaps); #1497
  (MethodSpec, shipped); #1471 (cross-package generic-arg linking).
- `docs/41-self-hosted-compiler-gap-analysis.md` §3 (H9), §5.4.
- D-progress-268 (`docs/10-bootstrap-progress.md`) — the table-driven FFI and
  the `Type.GetType`-null observation.
- Existing pure-Lyric metadata *writer*: `lyric-compiler/msil/pe.l`,
  `tables.l`, `heaps.l`, `lowering.l` (`bufMsilType`, `writeCompressedUInt`,
  coded-index encoders).
- ECMA-335 6th edition §II.24–25 (file format, metadata tables, signatures).
- Prior-art pure-Lyric binary parsers: `lyric-proto`, `Std.Xml`, `Std.Yaml`.
