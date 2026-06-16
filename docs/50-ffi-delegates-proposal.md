# FFI Target Delegate Instantiation (Proposal)

Provide a way to pass Lyric lambdas or method references to .NET methods expecting strongly typed delegates via auto FFI.

## Goal Description

Lyric's uniform ABI currently lowers all lambdas to `System.Func<object, ..., object>` or `System.Action`. .NET delegates are nominally typed, meaning the runtime rejects passing a `System.Func<object, object>` where a `System.Predicate<int>` is expected, even if the types structurally map to each other. This prevents Lyric from directly invoking many BCL and third-party library methods that take delegates. This proposal describes a bridging mechanism for the FFI layer.

## Proposed Changes

### 1. FFI Target Resolution (`type_checker`)
- Update `lyric-compiler/lyric/type_checker/` to unwrap the `.Invoke` signature of .NET `System.Delegate` subclasses during overload resolution.
- Provide a scoring mechanism allowing a Lyric `TFunction(params, ret)` to implicitly map to the delegate type if structurally compatible. 
- Introduce a new AST node to represent an implicit FFI adapter cast from a Lyric function expression to a specific nominal `.NET` delegate `TypeRef`.

### 2. Synthesizing Thunks (`msil/codegen.l`)
- When the MSIL generator encounters this adapter cast, it must emit a hidden static adapter method (a "thunk").
- The thunk method's signature must exactly match the target `.NET` delegate's signature (e.g., `bool Adapter(int x)`).
- **Thunk Body**: 
  - The thunk will take the boxed Lyric lambda closure array (`object[]`) as an implicit parameter.
  - It will box all incoming primitive parameters into `System.Object`.
  - It will call the standard `System.Func::Invoke` on the Lyric lambda.
  - It will unbox the returned `System.Object` back to the delegate's expected return type.

### 3. Call-site Emission (`msil/codegen.l`)
- Generate an `ldftn` instruction pointing to the newly synthesized thunk.
- Construct the target `.NET` delegate type (e.g., `newobj instance void class [mscorlib]System.Predicate\`1<int32>::.ctor(object, native int)`).
- Pass this strongly-typed delegate to the underlying .NET FFI call.

## Open Questions / Resolution

### Q: Performance overhead of boxing/unboxing parameters in hot loops
> [!WARNING]
> The performance overhead of boxing/unboxing parameters at every delegate invocation in hot loops (e.g., `Enumerable.Where`) might be non-trivial. Should we provide a way to emit strongly typed closures instead for specific contexts?

**Proposed Resolution**: We accept the overhead for now. Epic #1877 explicitly simplified the compiler by boxing all lambdas to a uniform `Func<object, ..., object>` ABI. Re-introducing strongly typed lambdas specifically for FFI would undo this simplification. If performance is critical, developers can write a high-performance interop layer in C# or F# and expose a simpler boundary to Lyric.

### Q: Distinguishing generic closures in `Lyric.Mono`
> [!IMPORTANT]
> How will we distinguish between the generic `System.Func` closures and nominal delegates in the `Lyric.Mono` monomorphization pass?

**Proposed Resolution**: `Lyric.Mono` operates on the AST before MSIL codegen and simply substitutes type variables. The new "adapter cast" AST node would hold a `TypeRef` to the target delegate. `Lyric.Mono` only needs to substitute any generic type variables inside that `TypeRef`. The actual distinction between Lyric closures and .NET delegates, and the subsequent thunk generation, happens later during MSIL emission (`codegen.l`), which handles concrete MSIL types and FFI metadata.

## Verification Plan

### Automated Tests
- Passing a simple lambda to `System.Collections.Generic.List<T>::RemoveAll(Predicate<T>)`
- Passing a method reference to a C# event handler
- A test explicitly passing primitive integers to verify boxing/unboxing within the thunk.
