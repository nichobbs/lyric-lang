# Strongly-Typed Lambda ABI (Epic #1877)

**Status:** Shipped — D113. Verified by `closure_zero_overhead_self_test.l`
(16 cases, MSIL + JVM parity). Implements `docs/52-strongly-typed-lambdas-proposal.md`.

Implement a strongly-typed MSIL lambda ABI to replace the interim uniform `Func<object, ..., object>` ABI, fulfilling Epic #1877. This plan implements Option 2A: synthesizing custom MSIL `.class` types for closure environments, completely eliminating primitive boxing and `object[]` arrays.

## User Review Required
> [!WARNING]
> This is a major structural change to code generation (`codegen.l`). Every lambda in the system will now be emitted as a strongly-typed `System.Func<T, R>` / `System.Action<T>`, and every capturing lambda will generate a new nested `.class` rather than an `object[]`. 

## Open Questions
None.

## Proposed Changes

### AST Monomorphization / FFI Bridging
We will no longer rely on `MObject` coercion. The Lyric TypeChecker already resolves `TFunction(params, ret)`.
- No new FFI adapter thunks are needed; lambdas will structurally match the target .NET delegates.

### Code Generation (`lyric-compiler/msil/codegen.l`)

#### [MODIFY] [codegen.l](../lyric-compiler/msil/codegen.l)
- **Closure Class Synthesis**:
  - Add a pass before or during `liftLambdasMsil` to synthesize a new `__Closure_<i>` MSIL `.class` for each capturing lambda.
  - For every captured variable (found via `lambdaCaptureNamesMsil`), add a strongly-typed MSIL `.field` to the closure class. If the capture is by-reference (a hoisted cell), the field's type is the `List[object]` cell type. Otherwise, it is the actual primitive/reference type.
- **Lambda Method Relocation**:
  - Change the lifted `__lambda_<i>` method from a static `IFunc` on the current class/module to an *instance* method on the newly synthesized `__Closure_<i>` class.
  - The method signature will use `HASTHIS = true`. The `__caps` parameter is completely removed.
- **Lambda Construction (`ELambda`)**:
  - Instead of `MLdcI4` and `MNewarr` to build an `object[]`, emit a `newobj` instruction targeting the default constructor of `__Closure_<i>`.
  - For each capture, push the value/cell and emit `stfld` to store it into the closure instance.
  - To create the delegate, push the closure instance, emit `ldftn` to the instance method `__lambda_<i>`, and `newobj` the strongly-typed `System.Func` / `System.Action` delegate.
- **Lambda Parameter Types (`lowerFuncMsil`)**:
  - Remove the logic that coerces lambda parameter types to `MObject`. Parameters will use their true `annotTy` or `lambdaPropagated` types directly in the method signature.
  - Remove the logic that coerces the return type to `MObject`. Return the true `retTy`.
  - Remove the synthetic `__caps` slot insertion.
- **Capture Resolution (`EPath` / Variable reads)**:
  - Inside a lambda, any access to a captured variable will emit `ldarg.0` (load `this` pointer) followed by an `ldfld` (or `stfld` for assignment) targeting the specific field in the closure class.
- **Lambda Invocation (`lowerMethodCallMsil`)**:
  - Function-typed values (`TFunction`) will be strongly typed. Remove any `box` instructions on arguments and `unbox.any` on the return value when emitting `callvirt` to `System.Func::Invoke`.

## Verification Plan

### Automated Tests
- Run `lyric test` against the compiler's own self-tests, specifically `lyric-compiler/lyric/closure_correctness_self_test.l`, which validates captures, by-reference mutations, and deep nesting.
- Add a new performance/interop test ensuring a primitive `(Int) -> Int` lambda runs inside a hot loop without causing heap allocations (verifying the MSIL output has no `box` instructions).

### Manual Verification
- Compile a snippet using a generic `.NET` FFI method that expects a `Predicate<Int>` to ensure the structural delegate instantiation succeeds.
