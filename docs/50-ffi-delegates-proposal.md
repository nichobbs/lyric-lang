# FFI Target Delegate Instantiation (Proposal)

Provide a way to pass Lyric lambdas or method references to .NET methods expecting strongly typed delegates via auto FFI.

## Goal Description

Currently, the MSIL emitter struggles with bridging Lyric lambdas to .NET delegates because of the interim "Uniform Func ABI" where all lambdas lower to `System.Func<object, ..., object>`. .NET delegates are nominally typed, meaning the runtime rejects passing a `System.Func<object, object>` where a `System.Predicate<int>` is expected.

With the upcoming transition to a strongly-typed lambda ABI (Epic #1877, see `docs/52-strongly-typed-lambdas-proposal.md`), Lyric lambdas will natively compile to strongly-typed `System.Func` closures. Because the Lyric lambda signatures will structurally match the .NET delegate signatures, this FFI bridging can be drastically simplified to a direct MSIL instantiation without any complex thunking or adapter synthesis.

## Proposed Changes

### 1. FFI Target Resolution (`type_checker`)
- Update `lyric-compiler/lyric/type_checker/` to unwrap the `.Invoke` signature of nominal .NET `System.Delegate` subclasses during overload resolution.
- Because Epic #1877 means the Lyric lambda is strongly typed, the type checker can perform a direct structural match between the Lyric `TFunction(params, ret)` and the target delegate's `.Invoke` signature.
- Introduce a new AST node to represent a direct FFI delegate cast.

### 2. Direct MSIL Delegate Instantiation (`msil/codegen.l`)
- Because the underlying Lyric lambda is now emitted as a strongly-typed instance method on a closure class (or a strongly-typed static method for non-capturing lambdas), we no longer need to synthesize adapter thunks.
- Generate an `ldftn` (or `ldvirtftn`) instruction pointing directly to the strongly-typed Lyric lambda method.
- Construct the target `.NET` delegate type by pushing the closure environment (or null for static) and the function pointer, then calling the delegate constructor (e.g., `newobj instance void class [mscorlib]System.Predicate\`1<int32>::.ctor(object, native int)`).
- The constructed delegate is now perfectly strongly-typed and can be passed directly to the underlying .NET FFI call.

## Open Questions / Resolution

### Q: Structurally mapping to generic delegates
> [!IMPORTANT]
> How will the MSIL generator know which concrete generic arguments to provide to a delegate like `System.Action<T>` when instantiating it?

**Proposed Resolution**: The AST's delegate cast node will carry the fully resolved target `MsilType` (which will be an `MTypeSpec` for closed generic delegates). The MSIL generator uses this exact `MsilType` when emitting the `newobj` instruction. 

## Verification Plan

### Automated Tests
- Passing a strongly-typed lambda `(Int) -> Bool` to `System.Collections.Generic.List<T>::RemoveAll(Predicate<T>)`.
- Passing a method reference to a C# event handler.
- Verify MSIL output to ensure no adapter thunks were generated and the lambda is instantiated directly into the nominal delegate type.
