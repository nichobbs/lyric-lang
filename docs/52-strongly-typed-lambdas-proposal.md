# Strongly-Typed Lambda ABI (Epic #1877 Proposal)

Transition Lyric's lambda emission from the interim uniform `Func<object, ..., object>` ABI to a strongly-typed MSIL lambda ABI.

## Goal Description

Currently, the Lyric compiler implements an interim "Uniform Func ABI" where all lambdas are lowered to `System.Func<object, ..., object>` (or `System.Action` for void parameterless lambdas). This was done to guarantee that lambda construction and invocation types matched without complex type tracking, preventing MSIL signature mismatches. 

However, this uniform ABI has significant drawbacks:
- **Performance Overhead**: Primitive types (`Int`, `Double`, `Bool`) passed into or returned from lambdas incur boxing and unboxing allocations on the heap.
- **JIT Defeat**: The .NET JIT compiler struggles to inline or aggressively optimize lambdas when all arguments are hidden behind `System.Object` boxing.
- **FFI Friction**: It breaks structural typing against nominal `.NET` delegates (like `Predicate<int>`), requiring expensive "adapter thunks" to bridge the FFI boundary.

This proposal describes how to implement a fully strongly-typed lambda ABI, fulfilling Epic #1877.

## Proposed Changes

### 1. Lambda Type Lowering (`msil/codegen.l`)
- Update `typeExprToMsilCtx` (and related type emission) so that `TFunction(params, ret)` lowers to the specific, strongly-typed `System.Func` or `System.Action` arity.
- A Lyric function `(Int, String) -> Bool` will now map exactly to `System.Func\`3<int32, string, bool>`.
- A Lyric function `(Int) -> Unit` will map exactly to `System.Action\`1<int32>`.

### 2. Lambda Synthesis and Closure Capture (`msil/codegen.l`)
- Currently, lifted lambda bodies (`__lambda_...`) are synthesized to take `object` parameters. Update the `FunctionDecl` synthesis for lambdas to retain the actual declared parameter types.
- **Closure Capture**: Captured variables are currently passed via an `object[] __caps` array. This array must be upgraded to support unboxed primitives. 
  - Option A: Change `__caps` to a strongly typed record/struct specifically synthesized for each lambda closure. This is the optimal .NET C# approach.
  - Option B (Interim): Retain `object[] __caps` for captured state, but strongly type the *actual arguments* of the lambda. Since captures are internal implementation details of the closure and evaluated less frequently than loop arguments, Option B is a safe incremental step.

### 3. Lambda Invocation (`msil/codegen.l`)
- Update `lowerMethodCallMsil` for function-typed value invocations (`f()`).
- The compiler will no longer need to emit `box` instructions for primitive arguments before calling `.Invoke()`, nor `unbox.any` on the return value.
- It will directly push the strongly-typed arguments onto the evaluation stack and call `.Invoke()` on the strongly-typed generic `System.Func` or `System.Action` type specification.

## Open Questions / Resolution

### Q: Synthesized Closure Structs vs. `object[]` Array
> [!IMPORTANT]
> Should we synthesize a custom MSIL `struct` for every lambda's closure capture (the C# compiler approach) or continue using an `object[]` array?

**Proposed Resolution**: We should synthesize a custom MSIL `.class` (closure environment) for each capturing lambda. The closure class will hold strongly-typed fields for each captured variable. The lambda will be emitted as an instance method on this closure class. This completely eliminates boxing for captured primitives and removes the `object[]` allocation, fulfilling the ultimate performance goals of a systems language.

## Verification Plan

### Automated Tests
- Primitive arithmetic within hot loops (e.g., passing a `(Int) -> Int` lambda to an iterator).
- Verify MSIL output to ensure `box` and `unbox.any` instructions are eliminated at the lambda invocation site.
- Ensure that nested closure captures correctly access the typed fields of their closure environments.
