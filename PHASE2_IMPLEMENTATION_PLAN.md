# Phase 2: Closure Class Synthesis with Instance Methods

**Epic**: #1877 Part 2  
**Status**: Design and Planning  
**Target**: Production-ready implementation with zero boxing/unboxing overhead for lambda captures

## Overview

Phase 2 converts lambda closures from a uniform object-array mechanism (Phase 1) to strongly-typed closure record classes with instance methods. This eliminates boxing/unboxing overhead and enables JIT inlining of capture access.

## Architecture

### Current Phase 1 (What We're Replacing)

```
Lambda: { x: Int, y: String ->
  x + 1
  where x and y are captured
}

Lowering produces:
- Static method: __lambda_0(object[] __caps, int x) -> object
- Construction: 
  1. new object[2]
  2. Store captured vars into array (with boxing if needed)
  3. Create delegate with static method + array as target
```

### Proposed Phase 2 (What We're Building)

```
Lambda: { x: Int, y: String ->
  x + 1
  where x and y are captured
}

Lowering produces:
- Closure record: __ClosureLambda_0 { x: Int, y: String }
- Constructor: __ClosureLambda_0(int x, string y) -> void
- Instance method: __lambda_0(self: in __ClosureLambda_0, int param) -> object
- Construction:
  1. Create instance: new __ClosureLambda_0(capturedX, capturedY)
  2. Create delegate with instance method + record as target
```

## Implementation Phases

### Phase 2.1: Closure Record Synthesis (Foundation)
- Generate __ClosureLambda_<idx> record types for lambdas with captures
- Add typed fields for each captured variable
- Generate parametrized constructors
- Integration points: codegen.l (generate MRecord), lowering.l (emit TypeDef/FieldDef rows)

### Phase 2.2: Lambda Method Refactoring
- Convert __lambda_<idx> from static to instance methods
- Change parameter list: remove object[] __caps, add self parameter
- Update capture access: from array indexing to field access
- Integration point: lowerFuncMsil parameter handling

### Phase 2.3: Lambda Construction Refactoring
- Change from object[] construction to record instantiation
- Update delegate target: closure record instance instead of array
- Add MNewobj for closure record construction
- Integration point: lowerExprMsil ELambda case

### Phase 2.4: Cross-Package Support
- Symbol table registration for closure record types
- Metadata encoding for closure records
- Integration points: bridge.l (symbol registration), lowering.l (metadata)

## Critical Design Decisions

### Decision 1: Closure Record Naming
- **Chosen**: `__ClosureLambda_<idx>` in the lambda's package namespace
- **Rationale**: Parallels lambda naming scheme, package-scoped to avoid conflicts
- **Alternative Considered**: Global __Closure_<uuid> (rejected: complex UUID generation)

### Decision 2: Record Visibility
- **Chosen**: Internal (`private` / `TDF_NOT_PUBLIC`)
- **Rationale**: Closure records are synthetic, not user-facing
- **Alternative Considered**: Public (rejected: leaks implementation details)

### Decision 3: Field Boxing for Value Types
- **Chosen**: Fields use actual capture types (no boxing)
- **Rationale**: Eliminates boxing overhead, main benefit of Phase 2
- **Alternative Considered**: All fields as object (rejected: defeats purpose)

### Decision 4: Constructor Style
- **Chosen**: Parametrized constructor that takes all captures as arguments
- **Rationale**: Matches Phase 1 capture array construction, simple initialization
- **Alternative Considered**: No-arg constructor + field assignment (rejected: more complex)

## File-by-File Changes

### lyric-compiler/msil/codegen.l
**Changes**:
- New function: `synthesizeClosureRecord(cctx, lambda_idx, package_name): MRecord`
  - Generates __ClosureLambda_<idx> record with typed fields
  - Creates parametrized constructor taking all captures
- Modify `codegenMPackage`: Call synthesis for each lambda with captures
- Modify `lowerExprMsil` ELambda case:
  - Check if closure record exists
  - If yes: use Phase 2 path (instantiate record)
  - If no: fall back to Phase 1 path (object array)

### lyric-compiler/msil/lowering.l
**Changes**:
- No changes needed (records lower normally through existing `lowerMRecord`)
- TypeDef/FieldDef rows are emitted by standard record lowering

### lyric-compiler/msil/bridge.l
**Changes**:
- Ensure closure record types are registered in symbol tables
- Add closure records to type resolution paths

### lyric-compiler/msil/codegen.l (lowerFuncMsil)
**Changes**:
- Detect if a __lambda_<idx> function is an instance method of its closure record
- If yes: skip the object[] __caps parameter prepending
- Change capture access from `__caps[i]` to field access on `this`
- Update closure-by-reference capture handling

## Testing Strategy

### Unit Tests (Per Component)
- `closure_record_synthesis_self_test.l`: Verify record type generation
- `closure_construction_self_test.l`: Verify closure instantiation with typed fields
- `closure_method_invocation_self_test.l`: Verify instance method invocation
- `closure_capture_access_self_test.l`: Verify field access vs array indexing

### Integration Tests
- `lambda_with_mixed_captures_self_test.l`: Value types, reference types, hoisted vars
- `nested_lambda_closures_self_test.l`: Lambdas capturing lambdas
- `lambda_parameter_propagation_self_test.l`: HOF type propagation with closures

### Regression Tests
- Rerun Phase 1 lambda tests with Phase 2 enabled
- Verify boxing/unboxing is eliminated (no unnecessary box/unbox instructions)
- Performance: closure access should be faster than array indexing

## Fallback and Compatibility

**Phase 2 Opt-In**:
- Phase 2 enabled by default when closure records are synthesized
- Phase 1 fallback only if closure record synthesis fails

**Phase 1 Compatibility**:
- Non-capturing lambdas unaffected (no closure record needed)
- Existing lambda tests continue to work
- Object[] mechanism kept as fallback

## Known Limitations and Future Work

### Not in Phase 2
1. Generic closures (type parameters in closure records) - deferred to Phase 2b
2. Metadata-based delegate detection - deferred to Phase 3 (docs/42)
3. Cross-package closure type visibility - research phase needed

### Tracked Issues
- #3910: Generic closure types
- #3911: Metadata-based delegate detection
- #3912: Cross-package closure records

## Success Criteria

Phase 2 is complete when:
1. ✅ All __ClosureLambda_<idx> records are generated correctly
2. ✅ Lambda methods are instance methods on closure records
3. ✅ Lambda construction instantiates closure records
4. ✅ Captures are accessed via fields (no array indexing)
5. ✅ No boxing/unboxing for value-type captures
6. ✅ All Phase 1 lambda tests pass
7. ✅ New Phase 2 tests verify the typed closure mechanism
8. ✅ JIT performance is improved for capture access
9. ✅ Both MSIL and JVM backends supported
