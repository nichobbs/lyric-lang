# Phase 2.2-2.4: Lambda Method and Construction Refactoring

**Prerequisite**: Phase 2.1 (closure record synthesis) - COMPLETE ✅

## Phase 2.2: Lambda Method Refactoring (Instance Methods)

### Current State (Phase 1)
Lambda methods are emitted as static functions with an `object[] __caps` first parameter:

```csharp
// Phase 1: Static lambda method
private static object __lambda_0(object[] __caps, int param) {
    // Access captures via array indexing: __caps[0], __caps[1], etc.
    // Implicit boxing for value types when stored in array
    return ...
}
```

### Target State (Phase 2)
Lambda methods become instance methods on their closure records:

```csharp
// Phase 2: Instance method on closure record
public class __ClosureLambda_0 {
    public int capturedX;
    public string capturedY;
    
    private object __lambda_0(int param) {
        // Access captures via instance fields: this.capturedX, this.capturedY
        // No boxing - fields already have correct types
        return ...
    }
}
```

### Implementation Steps

1. **Identify lambda functions** (in lowerFuncMsil):
   - Detect if function name starts with `__lambda_`
   - Check if closure record was synthesized for this lambda
   - If yes, treat as instance method

2. **Update method signature**:
   - Remove `object[] __caps` parameter
   - Add `self: in __ClosureLambda_<idx>` parameter (implicit receiver)
   - Keep the original lambda parameters unchanged

3. **Update capture access**:
   - Change `__caps[i]` array lookups to field access on `self`
   - Example: `__caps[0]` → `this.capturedX`
   - Maintain hoisted-var cell access logic

4. **Update method flags**:
   - Change from static to instance method
   - Set `MDA_FINAL` to prevent overrides
   - Keep `MDA_HIDE_BY_SIG` for correct virtual dispatch

### Code Locations to Modify

**File**: `lyric-compiler/msil/codegen.l`

1. **lowerFuncMsil** (line 16292+):
   - Check if `decl.name` is `__lambda_<idx>` AND closure record exists
   - Conditional logic:
     ```
     if isLambdaWithClosureRecord(cctx, decl.name):
         use Phase 2.2 path (instance method)
     else:
         use Phase 1 path (static method with object[] __caps)
     ```

2. **Capture parameter setup** (line 16322+):
   - Phase 1: `effectiveParamCount = decl.params.count + 1` (for __caps)
   - Phase 2: `effectiveParamCount = decl.params.count` (no __caps)
   - Replace __caps slot registration with self field registration

3. **Capture access** (lines resolving EPath for captured names):
   - Phase 1: `__caps[captureIndex]` via array load
   - Phase 2: `this.fieldName` via field read
   - Hoisted cells: still accessed via their hoisted cell slots

### Testing
Create `lambda_instance_method_self_test.l`:
```lyric
@test_module

pub func testLambdaAsInstanceMethod {
    val captured = 42
    val lambda = { x: Int -> x + captured }
    assert(lambda(8) == 50)
}

pub func testMultipleCapturesTyped {
    val x: Int = 10
    val y: String = "hello"
    val lambda = { z: Int -> z + x }
    assert(lambda(5) == 15)
}
```

## Phase 2.3: Lambda Construction Refactoring

### Current State (Phase 1)
Lambdas are constructed by creating an object array and passing it as the delegate target:

```msil
// Phase 1: object[] construction
ldc.i4 2                              // array size
newarr object
// ... store captures into array ...
ldftn __lambda_0                      // static method
newobj System.Func<int, object>:.ctor(object, IntPtr)
```

### Target State (Phase 2)
Lambdas are constructed by instantiating closure records:

```msil
// Phase 2: Closure record instantiation
ldc.i4 <capturedX>                   // load captured value
ldstr <capturedY>                    // load captured value (no boxing needed)
newobj __ClosureLambda_0:.ctor(int, string)
ldftn __ClosureLambda_0.__lambda_0   // instance method
newobj System.Func<int, object>:.ctor(object, IntPtr)
```

### Implementation Steps

1. **Detect closure availability** (in lowerExprMsil, ELambda case):
   ```
   if closureRecordExists(cctx, lambda_idx):
       use Phase 2.3 path (record instantiation)
   else:
       use Phase 1 path (object array)
   ```

2. **Load captured values**:
   - For each capture in order:
     - Load the captured variable via emitLoadVarMsil
     - **IMPORTANT**: No boxing! Field types are already correct
     - Example: `Int` field accepts `ldc.i4` directly

3. **Instantiate closure record**:
   - Emit `newobj __ClosureLambda_<idx>:.ctor(...captures...)`
   - Constructor takes captures in declaration order

4. **Create delegate**:
   - Emit `ldftn __ClosureLambda_<idx>.__lambda_<idx>`
   - Emit `newobj System.Func<...>:.ctor(object, IntPtr)`
   - Closure record instance is the delegate target (not null or array)

### Code Locations to Modify

**File**: `lyric-compiler/msil/codegen.l`, `lowerExprMsil` ELambda case (~line 6110+)

1. **Phase 2 construction path**:
   ```lyric
   if closureRecordExists(cctx, idx):
       // Load captures (no boxing for typed fields)
       for each capture:
           emitLoadVarMsil(fctx, insns, capture_slot)
           // Don't box - field is already typed correctly
       
       // Create closure record instance
       insns.add(MNewobjByName(className = closureFqn))
       
       // Create delegate with record as target
       insns.add(MLdftn(methodToken = tok))
       insns.add(MNewobj(ctorToken = ctorTok))
   else:
       // Fall back to Phase 1 (object array)
       ...
   ```

2. **Boxing elimination**:
   - **REMOVE** `boxIfNeededMsil(cctx, insns, capTypes[i])` calls
   - Typed fields accept their native types directly
   - Verify: `Int` field gets `ldc.i4` (not `box`), `String` field gets `ldstr`, etc.

### Testing
Create `lambda_typed_construction_self_test.l`:
```lyric
@test_module

pub func testInt32Capture {
    val x: Int = 42
    val f = { -> x }
    assert(f() == 42)
}

pub func testStringCapture {
    val s: String = "hello"
    val f = { -> s.length }
    assert(f() == 5)
}

pub func testMixedCaptures {
    val i: Int = 10
    val s: String = "x"
    val f = { -> i + s.length }
    assert(f() == 11)
}
```

## Phase 2.4: Cross-Package Closure Support

### Overview
Enable closure records to be:
- Referenced across package boundaries
- Resolved during symbol table construction
- Encoded in metadata for restored packages

### Implementation Steps

1. **Symbol table registration** (bridge.l):
   - Register closure record types in cross-package symbol tables
   - Key: `<packageName>.__ClosureLambda_<idx>`
   - Value: TypeRef/TypeDef row

2. **Metadata encoding** (contract metadata):
   - Include closure record type information in restored packages
   - Allow consumer packages to resolve closure records via metadata

3. **Fallback mechanism**:
   - If closure record type is not in symbol table, fall back to object array ABI
   - Ensures compatibility with older compiled packages

### Testing
Create `cross_package_closure_self_test.l`:
```lyric
@test_module

import OtherPackage

pub func testCrossPackageCapture {
    val factory = OtherPackage.makeLambda(42)
    assert(factory() == 42)
}
```

## Verification Checklist

After implementing each phase, verify:

- [ ] Code compiles (stage1-fast)
- [ ] New tests pass
- [ ] Phase 1 lambda tests still pass
- [ ] No boxing/unboxing instructions in lambda methods
- [ ] Instance methods have correct method flags
- [ ] Closure record constructors are called correctly
- [ ] Capture types are preserved (no object-typed fields)
- [ ] Cross-package references resolve correctly (Phase 2.4)

## Risk Mitigation

1. **Gradual Rollout**:
   - Phase 2.2-2.4 are gated on closure record existence
   - Phase 1 path remains the fallback for any issues
   - Can disable Phase 2 entirely by commenting synthesizeClosureRecordsPhase2()

2. **Testing**:
   - Create comprehensive self-tests before each phase
   - Run full lambda test suite after each change
   - Performance benchmarks for capture access

3. **Code Review**:
   - Each phase is a separate PR
   - Clear separation of concerns
   - Early feedback on design decisions

## Timeline Estimate

- **Phase 2.2** (Instance Methods): 3-4 hours dev + 2 hours testing
- **Phase 2.3** (Construction): 3-4 hours dev + 2 hours testing
- **Phase 2.4** (Cross-Package): 2-3 hours dev + 1 hour testing
- **Total**: ~17 hours development + testing

## Success Metrics

Phase 2 complete when:
1. All closure records are generated with typed fields ✅ (Phase 2.1 done)
2. Lambda methods are instance methods on closure records (Phase 2.2)
3. Lambda construction instantiates closure records (Phase 2.3)
4. No boxing/unboxing in lambda capture access (Phase 2.3)
5. Cross-package closure records work (Phase 2.4)
6. All Phase 1 tests still pass
7. New Phase 2 tests verify the mechanism
8. Performance improves for capture-heavy lambdas
