# Phase 2 Closure Synthesis Implementation - Findings & Next Steps

## Summary

The task is to implement **proper Phase 2 closure class synthesis** where `__lambda_<N>` functions become instance methods of their corresponding `__Closure<N>` records, allowing .NET to create proper delegates.

## Current Problem

The current implementation (Phase 1):
- Creates `__Closure<N>` records with captured variables as fields
- But `__lambda_<N>` functions remain as **top-level static functions**
- At instantiation, tries to pass a closure instance to a static function
- .NET delegates don't work this way - they need instance methods

## Key Findings

### 1. Methods in Types Are Desugared (D037)

From `docs/49-methods-in-types.md`:
- Methods inside type definitions desugar to UFCS-style functions during parsing
- The parser hoists `record { func foo() {} }` to a top-level `record.foo(self: in record) {}`
- This happens at **parse time**, not at codegen time

### 2. Methods Can Be Added to MRecord at Lowering Time

The existing code shows two patterns for adding methods to records at lowering time:
1. `injectImplMethodsIntoRecord` (line 20178) - adds impl methods from IImpl blocks
2. `appendDeriveOverridesMsil` (line 20238) - adds derived Equals/GetHashCode overrides

Both show how to inject methods into an MRecord after it's been created.

### 3. RMFunc Hoisting Not Yet Implemented for Synthesized Members

- The parser's `injectSelfIfNeeded` (parser_items.l:212) automatically adds `self` to RMFunc methods during parsing
- But `synthesizeClosureRecordsForFile` is called **after** parsing and type-checking
- So synthesized RMFunc members won't get the automatic `self` injection or hoisting

### 4. Pipeline Architecture

```
liftLambdasMsil
   ↓ (creates __lambda_<N> IFunc items)
synthesizeClosureRecordsForFile
   ↓ (creates __Closure<N> RecordDecl items)
type-check & mode-check
   ↓
addPackageTokens
   ↓ (registers MethodDef tokens)
codegenMPackage
   ↓ (walks AST, produces MPackage)
   ├─ For each IRecord: calls lowerRecordMsil
   ├─ For each IFunc: calls lowerFuncMsil
   └─ For each IFunc matching __lambda_*: creates MFunc in fns list
lowerMPackageWithCtx
   ↓ (lowers MPackage to PE bytes)
```

## Recommended Implementation Approach

### Strategy: Add Lambda Methods During Record Lowering

Instead of moving __lambda_* into RecordDecl as RMFunc (which requires AST hoisting), add them as MFunc during MRecord lowering:

#### Phase 2a: Track Closure Methods

1. **Enhance CodegenCtx** (around line 51-290):
   ```lyric
   closureMethodTokens: Map[String, Int]  // "__Closure<N>/__lambda_<N>/arity" -> token
   closureMethodInstances: Map[Int, String]  // lambda index -> closure class name
   ```

2. **Update scanClosureRecordsMsil** (line 18035):
   - When a __Closure<N> record is found, save the mapping from N to "__Closure<N>"
   - Populate `closureMethodInstances[N] = "__Closure" + toString(N)`

#### Phase 2b: Add Instance Methods During Record Lowering

1. **Enhance lowerRecordMsil** (line 15404):
   - Check if this record is a __Closure<N> (extract N from className)
   - If yes, find the matching __lambda_<N> FunctionDecl in the original file
   - Lower it as an instance method: add `self` as first parameter, lower with closure context
   - Add the resulting MFunc to the record's methods list

   ```lyric
   pub func lowerRecordMsil(cctx: in CodegenCtx, decl: in RecordDecl, pkgName: in String): MRecord {
     // ... existing field lowering ...
     
     // Phase 2: If this is a closure record, add the __lambda_<N> instance method
     val closureNum = extractClosureNumber(decl.name)  // __Closure<5> -> 5
     if closureNum >= 0 {
       match findLambdaFunctionForClosure(cctx, closureNum) {
         case Some(lambdaFunc) -> {
           val methodMFunc = lowerClosureMethod(cctx, lambdaFunc, className, pkgName)
           methods.add(methodMFunc)
         }
         case None -> ()
       }
     }
     
     MRecord(..., methods = methods, ...)
   }
   ```

#### Phase 2c: Update Token Registration

In `addPackageTokens` (around line 2037-2060), when registering RMFunc method tokens:
- Also check if this is a lambda method inside a closure record
- Register it with a closure-specific key format: `"__Closure<N>/__lambda_<N>/<arity>"`

#### Phase 2d: Update ELambda Codegen

In `lowerExprMsil` for ELambda (line 5542-5765):
- Check if this lambda has a closure record: `mapGet(cctx.lambdaHasClosures, lambda_idx)`
- If yes:
  1. Instantiate the closure record
  2. Look up the instance method token: `methodToken = mapGet(cctx.closureMethodTokens, fqn)`
  3. Create a delegate from the instance method instead of a static function

#### Phase 2e: Update FuncCtx for Closure Methods

When lowering a __lambda_* function that's a closure method:
- Set a flag: `fctx.isClosureMethod = true`
- Set the closure class: `fctx.closureClassName = "__Closure" + toString(lambdaIdx)`
- **Don't** add the synthetic `__caps` parameter to slot 0
- Map captured variable names directly to `self.<fieldname>` accesses

#### Phase 2f: Update EPath Codegen for Self-Field Access

In `lowerExprMsil` for EPath (line 4625-4700):
- When resolving a name that's in `captureNameToIndex`:
  - Check if this is a closure method (`fctx.isClosureMethod`)
  - If yes, emit: load `self` (slot 0), load field from self
  - If no, emit: load `__caps` array, load index from array

## Files to Modify

| File | Section | Lines | Changes |
|------|---------|-------|---------|
| `lyric-compiler/msil/codegen.l` | CodegenCtx record | 51-290 | Add `closureMethodTokens` and `closureMethodInstances` maps |
| `` | scanClosureRecordsMsil | 18035-18060 | Populate instance map |
| `` | addPackageTokens | 2030-2100 | Register closure method tokens |
| `` | lowerRecordMsil | 15404-15442 | Add __lambda_<N> method to __Closure<N> records |
| `` | ELambda codegen | 5542-5765 | Use instance method token for closure lambdas |
| `` | FuncCtx makeFuncCtxMsil | ~10920 | Add `isClosureMethod`, `closureClassName` fields |
| `` | EPath codegen | 4625-4700 | Handle self-field access for closure captures |
| `lyric-compiler/msil/lowering.l` | lowerMRecord | ~2415 | (verify it handles methods list correctly) |

## Test Cases to Add

Create self-tests in `lyric-compiler/msil/codegen_self_test.l`:

1. **Simple closure** - single captured variable, single lambda parameter
2. **Multiple captures** - 3+ captured variables of different types
3. **Nested closures** - lambda inside lambda
4. **Closure in HOF** - lambda passed to higher-order function
5. **Closure with mutable capture** - capturing a var (hoisted cell)
6. **Delegate instantiation** - verify the delegate can be invoked

## Risk Analysis

| Risk | Mitigation |
|------|-----------|
| Breaks Phase 1 fallback | Keep Phase 1 code path active for non-closure lambdas |
| Token registration collision | Use closure-specific key format to avoid conflicts |
| Self parameter resolution | Self type is well-understood by type-checker |
| Instance method emission | Pattern already used for impl methods |

## Next Steps for Implementer

1. **Read these files** for context:
   - `docs/49-methods-in-types.md` - method desugaring
   - `docs/41-self-hosted-compiler-gap-analysis.md` - Band 4 (metadata resolution)
   - PR #3867 and #3868 for recent closure work

2. **Start with Phase 2a**: Add the tracking maps to CodegenCtx and update scanClosureRecordsMsil

3. **Implement Phase 2b**: The lowerRecordMsil enhancement - this is the key piece

4. **Work through 2c-2f** in order, testing after each phase

5. **Run self-tests**: Make sure all closure patterns work correctly

## Related Issues

- #1877 - Strongly-typed lambda ABI (Phases 1-2)
- #1479 - Capturing closures (Phase 1 foundation)
- #2012 - By-value capture of immutable bindings
- #1939 - HOF-type propagation for parameter-taking lambdas
- #3912 - Review showing the current broken state

## References

- `docs/09-msil-emission.md` - MSIL strategy
- `docs/41-self-hosted-compiler-gap-analysis.md` - compiler gaps
- Commit `7ecab220` - Previous Phase 2 attempt (closure record synthesis)
- Commit `d1544017` - Original Phase 1 closure implementation
