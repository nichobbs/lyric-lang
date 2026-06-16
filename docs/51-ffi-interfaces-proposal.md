# Implementing External .NET Interfaces (Proposal)

Provide a way for Lyric programs to explicitly implement an interface defined in a compiled `.NET` dependency across the Auto FFI boundary.

## Goal Description

Lyric currently supports mapping FFI types to `extern type` and `extern package` declarations, but it lacks the AST nodes to represent an `extern interface`. Furthermore, Lyric's `impl` blocks only support binding a native Lyric record to a native Lyric `interface`. Since many `.NET` APIs require you to pass an object implementing a specific interface (e.g., `IEnumerable`, `IDisposable`, custom callback interfaces), providing a way to construct and pass instances of these interfaces directly from Lyric would improve interoperability. 

## Proposed Changes

### 1. FFI Syntax Extensions (`parser` & `ast`)
- Add support for `extern interface` declarations within `extern package` blocks.
- Add an `EMExternInterface` node to the `ExternMember` AST enum.
- Update `lyric-compiler/lyric/parser/` to parse method signatures within `extern interface` blocks.

```lyric
extern package System {
  extern interface IDisposable {
    func Dispose(): Unit
  }
}
```

### 2. Impl Binding Enhancements (`type_checker`)
- Update the type checker's `impl` conformance checks to allow implementing `extern interface` targets.
- Ensure that the Lyric implementation structurally matches the `.NET` interface signature (including any primitive boxing requirements expected by the FFI boundary, if applicable).

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
> If an external interface contains properties or events, how will those map to Lyric syntax, since Lyric does not have properties (only methods and fields)?

**Proposed Resolution**: In .NET, properties and events are syntactic sugar over standard methods (e.g., `get_Count()`, `add_Changed(EventHandler)`). The `extern interface` declaration in Lyric will explicitly declare these underlying methods:
```lyric
extern interface ICollection {
  func get_Count(): Int
}
```
The .NET runtime interface dispatch links implementations by method name and signature. When Lyric emits a standard method named `get_Count`, it will correctly satisfy the interface's property getter requirement in the MSIL `MethodImpl` table.

## Verification Plan

### Automated Tests
- Implement `System.IDisposable` on a Lyric record and pass it to a C# method that calls `.Dispose()`.
- Implement a custom C# interface with multiple methods from a referenced `.dll`.
- Test implementing a generic .NET interface (e.g., `System.IEquatable<int>`).
