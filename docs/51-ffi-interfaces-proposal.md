# Implementing External .NET Interfaces

> **Status.** Specced in D105.
> Phase 1 (non-generic interface emission) shipped: codegen resolves
> the FQN via the existing extern-type table (`implIfaceNameMsil`
> consults `cctx.externTypeNames`), reserves the TypeRef row in
> `collectImplEntriesMsil` via `internFfiTypeRefNested`, and
> `lowerMImpl` reuses its existing TypeRef path.
> Phase 2 (metadata-based signature validation) shipped: the
> `validateExternImplConformanceMsil` pass calls
> `Mdr.inspectInterfaceTarget` on the reference assembly, emits
> `F0020` (not-an-interface), `F0021` (missing required method),
> `F0022` (parameter arity / type mismatch), `F0023` (return type
> mismatch). Validation is skipped without diagnostic when the
> reference pack is absent (mirrors F0015), and per-method when the
> interface signature mentions a generic / byref / array shape.
> Generic external interfaces, the `get_`/`set_` property convention
> (the underlying methods are validated like any other; only the LSP
> scaffolding is missing), and bridge-thunk synthesis remain deferred.

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
