# Implementing External .NET Interfaces

> **Status.** Specced in D105. **Functionally complete.**
>
> | Phase | Slice | Shipped in |
> |---|---|---|
> | 1 | Non-generic InterfaceImpl emission | #3851 |
> | 2 | F0020–F0023 metadata-based signature validation | #3856 |
> | 3 | Widening to extern-interface-typed bindings / parameters | #3857 |
> | 4 | Closed generic external interfaces (TypeSpec + CLR name-match) | #3862 |
> | §A (i) | STVar substitution for F0022/F0023 on generic ifaces | #3864 |
> | §A (ii) | F0024 lift for STSzArray / STByRef | #3864 |
> | §A (iii) | F0024 lift for STNamedGenericInst | #3865 |
> | §A (iv) | F0024 removed entirely | #3865 |
> | §B | LSP "Implement <Iface>" code action | #3861 |
> | §C | Bridge-thunk synthesis | N/A — Lyric primitives are native CLR primitives |
>
> `F0024` is gone: TypeSpec emission produces structurally-valid IL for
> any closed instantiation, Phase 2 F0020–F0023 catches every
> build-time-detectable structural mismatch (with `STVar` substitution
> and recursive `STSzArray` / `STByRef` / `STNamedGenericInst` handling),
> and the runtime catches the rest as `TypeLoadException`.
>
> Explicitly deferred (rare in BCL; silent-skip F0022/F0023 with runtime
> as the backstop): `STMVar` (method-generic iface methods),
> `STArray` rank > 1, `STPtr` / `STFnPtr`, `STUnknown`.  See
> "Remaining work" §F0024 for details.

Provide a way for Lyric programs to explicitly implement an interface defined in a compiled `.NET` dependency across the Auto FFI boundary.

## Goal Description

Lyric currently supports mapping FFI types to `extern type` and `extern package` declarations, but it lacks the AST nodes to represent an `extern interface`. Furthermore, Lyric's `impl` blocks only support binding a native Lyric record to a native Lyric `interface`. Since many `.NET` APIs require you to pass an object implementing a specific interface (e.g., `IEnumerable`, `IDisposable`, custom callback interfaces), providing a way to construct and pass instances of these interfaces directly from Lyric would improve interoperability. 

## Proposed Changes

### 1. FFI Target Resolution (`type_checker`)
- **No New Syntax Required**: We can leverage the existing `extern type` and metadata resolution system that landed in Phase 4. Users simply import the interface the same way they import a .NET class using the `import extern` syntax:
  ```lyric
  import extern System.{ IDisposable as IDisposable }
  ```
- The compiler's metadata reader (`lyric-compiler/msil/pe.l`) already parses the .NET `TypeDef` table and can identify if an `extern type` represents a `.NET` interface (via the `ClassSemanticsMask`).
- When an `impl` block targets an `extern type`, the type checker queries the metadata cache to extract the expected interface method signatures (names, parameters, return types).

### 2. Impl Binding Enhancements (`type_checker`)
- Update the type checker's `impl` conformance checks to allow implementing `extern type` targets *if* the metadata indicates the target is a `.NET` interface.
- Ensure that the Lyric implementation structurally matches the `.NET` interface signature extracted from metadata (including any primitive boxing requirements expected by the FFI boundary, if applicable).

### 3. MSIL Type Emission (`msil/codegen.l`)
- When generating the `.class` definition for the implementing Lyric record in `lowerTypeDefMsil`, include the `.NET` interface TypeRef in the `implements` list of the MSIL class headers (`InterfaceImpl` metadata row).
- **VTable Wiring**: Map the Lyric methods bound in the `impl` block to the corresponding MSIL `.override` slots using `MethodImpl` table rows, or rely on implicit name-and-signature matching where the CLR wires up methods automatically.
- **Boxing/Unboxing**: If the `.NET` interface expects unboxed primitive arguments but Lyric methods expect boxed `System.Object` under the uniform ABI, we may need to synthesize bridge methods (thunks) on the class that satisfy the `.NET` interface signature, unbox/box the parameters, and then delegate to the actual Lyric method implementation.

## Open Questions / Resolution

### Q: Generic external interfaces
> [!IMPORTANT]
> How will we handle generic external interfaces like `IEnumerable<T>`? The `.NET` type parameters need to map to Lyric type parameters, and the structural MSIL emissions will need to support instantiating the closed interface TypeRef.

**Proposed Resolution**: Lyric already parses generic FFI types (`extern type IEnumerable[T]`). When a Lyric record implements this interface, the type checker will instantiate the interface with concrete types. During MSIL emission (`codegen.l`), the implementation list for the `.class` will use the existing `MTypeSpec` machinery (which builds closed generic types) instead of a plain `MClassRef`, mapping the Lyric type arguments directly to the .NET type arguments.

### Q: Properties and events in external interfaces
> [!WARNING]
> How will a Lyric implementer know what the correct method is for a property or event? Do we need a `prop` syntax for interfaces?

**Proposed Resolution**: We do not need a new `prop` syntax. The .NET metadata encodes properties and events as standard methods with special prefixes (e.g., `get_Count()`, `set_Count()`, `add_Changed()`). The type checker will extract these underlying method signatures from the interface metadata. The user will satisfy the interface by following the standard .NET convention and implementing standard Lyric methods matching those underlying names:
```lyric
impl ICollection for MyList {
  func get_Count(): Int { return self.size }
}
```
The .NET runtime interface dispatch automatically wires this `MethodImpl` to the property getter requirement. To aid discoverability, the Lyric LSP/VS Code extension will automatically scaffold the correct `get_`/`set_` method signatures when a user invokes "Implement Interface".

## Verification Plan

### Automated Tests
- Implement `System.IDisposable` on a Lyric record and pass it to a C# method that calls `.Dispose()`.
- Implement a custom C# interface with multiple methods from a referenced `.dll`.
- Test implementing a generic .NET interface (e.g., `System.IEquatable<int>`).

## Remaining work — final state

Phases 1–4 and follow-ups A, B, C are all shipped:

| § | Item | Status |
|---|---|---|
| Phase 1 | Non-generic InterfaceImpl emission | Shipped in #3851 |
| Phase 2 | F0020–F0023 metadata-based signature validation | Shipped in #3856 |
| Phase 3 | Widening to extern-interface-typed bindings / parameters | Shipped in #3857 |
| Phase 4 | Closed generic external interfaces — TypeSpec + CLR name-matching | Shipped in #3862 |
| §A (i) | STVar substitution for F0022/F0023 on generic ifaces | Shipped in #3864 |
| §A (ii) | F0024 lift for STSzArray / STByRef | Shipped in #3864 |
| §A (iii) | F0024 lift for STNamedGenericInst (nested generic types) | Shipped in #3865 |
| §A (iv) | F0024 narrowed to "iface type not found in metadata" | Shipped in #3865 |
| §B | LSP "Implement Interface" code action (native + extern) | Shipped in #3861 |
| §C | Bridge-thunk synthesis | N/A (see below) |

### F0024 — removed

`F0024` was removed in #3865.  TypeSpec emission produces
structurally-valid IL for any closed instantiation, and Phase 2's
F0020 / F0021 / F0022 / F0023 catches every build-time-detectable
structural mismatch — with `STVar` substitution against the iface's
resolved type args and recursive shape handling for `STSzArray`,
`STByRef`, and `STNamedGenericInst`.  The only previously-imagined
F0024 role (typo guard for "iface FQN not in reference-assembly
TypeDef table") proved unreachable in practice: `Mdr.assemblyForType`
returns `None` for an unknown FQN and the validation path silently
skips, so the panic site never fired.  The wider FFI contract — runtime
catches genuine mismatches as `TypeLoadException` — covers the typo
case at first use instead.

### Explicitly deferred (no real-world impact)

The following metadata signature shapes silent-skip per-method F0022/F0023
structural validation, but still surface F0021 if the impl is missing
the method by name. The runtime catches structural mismatches at
type-load.

- **`STMVar`** — method-generic iface methods (e.g. `T Bar<U>()`). Rare
  in BCL; supporting validation requires `MTypeVar` to distinguish
  type-generic (VAR 0x13) from method-generic (MVAR 0x1E) tokens in
  signatures, plus GenericParam table rows on the impl `MethodDef`.
- **`STArray` rank > 1** — multi-dim arrays (`int[,]`). Lyric's array
  type maps to single-dim `MArray`; multi-dim arrays aren't
  expressible in Lyric impl methods.
- **`STPtr` / `STFnPtr`** — unmanaged pointers / function pointers.
  Out of scope for the managed FFI; the BCL interfaces that use these
  aren't on the supported FFI surface.
- **`STUnknown`** — element bytes the metadata decoder doesn't
  recognize. Defensive default for forward compatibility.

### §B — shipped in #3861

`handleCodeAction` at `lyric-compiler/lyric/lsp.l:1414` now dispatches
an "Implement <Iface>" action whenever the request range overlaps an
`impl Iface for Record { … }` block:

- **Native interfaces** (`DKInterface`) — walks `IMSig` members; renders
  types via a small structural printer (primitives, refs, generics).
- **Extern interfaces** (`DKExternType`) — lazily builds reference-pack
  type/path indexes on first request, then calls
  `Mdr.inspectInterfaceTarget` and renders BCL→Lyric primitives.

The `get_X`/`set_X` SpecialName scaffolding noted in the original §B
plan was not separately implemented: the property's underlying
get/set methods are surfaced by the same code action like any other
abstract method, which is sufficient for the v1 use case. A
friendlier "Implement property X" label is a small UX enhancement
that can be added if user feedback asks for it.

### §C — Bridge thunks (N/A)

The proposal's worry was that Lyric might use a uniform boxed-object
ABI requiring bridge thunks to unbox primitive arguments for the .NET
interface. **This concern does not apply to Lyric MSIL today**: `Int`
= ECMA element type `0x08` (int32), `Long` = `0x0A` (int64), `Double`
= `0x0D`, etc. — all native CLR primitives, never boxed in record
fields or method signatures. The F0022/F0023 validation pass enforces
by-value primitive matching, and the InterfaceImpl emission produces
a MethodDef whose signature is the native primitive shape. No bridge
thunks are needed.

The only hypothetical thunk requirement is when an iface method
takes a value-type receiver passed by reference (`int& this`) and
the Lyric impl can't express that. The structural-validation pass
catches the mismatch via F0022 (parameter type) rather than
silently miscompiling; no thunk synthesis is needed or planned.
