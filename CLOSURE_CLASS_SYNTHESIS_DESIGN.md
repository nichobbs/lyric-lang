# Epic #1877: Strongly-Typed Lambda ABI — Closure Class Synthesis Design

**Date:** 2026-06-19  
**Status:** Design Phase (pre-implementation)  
**Related Files:**
- `lyric-compiler/msil/codegen.l` — ELambda lowering, lambda lifting
- `lyric-compiler/msil/lowering.l` — MSIL IR types, PE emission
- `lyric-compiler/msil/bridge.l` — Entry point, pipeline orchestration

---

## 1. Current State

### 1.1 Current Lambda ABI

Lambdas are currently lowered to static methods with a boxed `object[] __caps` parameter:

```
// Lyric code:
val x = 42
val f = { () -> x }

// Current lowering:
class __lambda_0 {
  static object Invoke(object[] __caps) {
    return __caps[0];  // unbox and cast to Int
  }
}

// Construction:
object[] caps = new object[1];
caps[0] = 42;  // box
Func<object> delegate = new Func<object>(__lambda_0.Invoke, caps);
```

**Problems:**
- All parameters boxed/unboxed via `boxedParamTypes` workaround
- Captures stored in untyped `object[]` arrays
- Boxing overhead on every parameter and capture access
- No type safety — all captures are `object` until runtime unboxing
- Complicates JVM target (which uses different closure representation)

### 1.2 Current Implementation Locations

**Phase 3 (Codegen — `lyric-compiler/msil/codegen.l`):**
- Lines 5530–5699: `ELambda` case in `lowerExprMsil`
  - Captures computed via `lambdaCaptureNamesMsil`
  - Delegate constructed with `ldftn` + `newobj` (System.Func ctor)
  - `object[]` array allocated and populated at runtime
  
- Lines 14603–14690: `lowerFuncMsil` lambda path
  - Reserve slot 0 for `object[] __caps`
  - Register capture names in `captureNameToIndex` / `captureNameToType`
  - `boxedParamTypes` seeds type info for un-annotated params (#1939)

**Phase 0 (Lambda Lifting — `lyric-compiler/msil/codegen.l`):**
- Lines 16960–19942: `liftLambdasMsil` + BFS collectors
  - Extract `ELambda` nodes into synthetic `__lambda_<i>` IFunc items
  - Pre-assigned MethodDef tokens before codegen Phase 3

**Phase 5 (Lowering — `lyric-compiler/msil/lowering.l`):**
- MethodDef/Field emission via `lowerMFunc` / `lowerMRecord`

---

## 2. Design: Closure Class Synthesis

### 2.1 Architecture Overview

**Key Change:** Replace the runtime `object[] __caps` array with synthesized **closure class instances**.

For each lambda with captures:
1. **During Lambda Lifting (Phase 0):** Synthesize a closure class `__closure_<i>` alongside the lambda method `__lambda_<i>`
2. **During Codegen (Phase 3):** Emit code to construct the closure instance and pass it as a typed target
3. **During Lowering (Phase 5):** Emit the closure class TypeDef with typed fields (no boxing required)

**Strongly-Typed Delegate Construction:**
```
// Lyric code:
val x = 42
val f = { () -> x }

// New lowering:
class __closure_0 {
  public int x;
  
  __closure_0() { }
}

class __lambda_0 {
  static object Invoke(__closure_0 __closure) {
    return __closure.x;  // Direct field access, typed
  }
}

// Construction (Phase 3 codegen):
__closure_0 __closure = new __closure_0();
__closure.x = 42;           // Direct field store, no box
Func<object> delegate = new Func<object>(__lambda_0.Invoke, __closure);
```

### 2.2 Minimal Viable Implementation (Phase 1)

**Scope Constraints:**
1. **Non-generic closures only** — defer `__closure_0<T>` to later phase
2. **By-value captures only** — defer by-reference cells (hoisted `var`) to v1.1
3. **No nested lambdas** — defer closure-capturing-closure to v1.1
4. **Single-closure-field initialization** — only `new __closure()` with explicit field stores
5. **Closure-per-lambda** — no deduplication across lambdas that capture same variables

**Success Criteria:**
- Non-capturing lambda remains static (no closure class synthesized)
- Single-capture lambda synthesizes typed closure class with one field
- Multi-capture lambda synthesizes closure class with multiple typed fields
- Captured values passed **by reference** from closure to lambda (no re-boxing)
- Closure instances constructed at call site with explicit field initialization
- All MSIL self-tests pass without modification

### 2.3 Type Representation

**New MSIL IR type variant (in `lowering.l`):**

```lyric
// In MPackageItem union:
case MPClosureClass(closure: MClosureClass)

// New record type:
record MClosureClass {
  className: String          // e.g. "__closure_0"
  namespace: String          // e.g. "Pkg"
  fields: List[MField]       // closure fields (public, by-value captures)
  // Default .ctor (newobj allocates, caller initializes fields)
  useDefaultCtor: Bool = true
}
```

**Alternative (reuse MRecord):** Closure classes could reuse the existing `MRecord` type by setting a flag to suppress `useDefaultCtor: false` and emit only a default constructor. This minimizes churn but requires a semantic distinction (closure classes are always sealed, never have user methods).

**Recommendation:** Use dedicated `MClosureClass` for semantic clarity. Codegen (Phase 3) emits fewer properties than a user record.

### 2.4 Pipeline Changes

#### Phase 0: Lambda Lifting (codegen.l)

**Current:** `liftLambdasMsil` extracts `ELambda` → `__lambda_<i>` IFunc.

**New:**
1. For each captured lambda, **also synthesize** a companion `__closure_<i>` type declaration
2. Store mapping `__lambda_<i>` → (`__closure_<i>`, field names, field types)
3. Register closure class in `cctx.lambdaClosureClasses: Map[String, MClosureClass]`

**Pseudocode:**
```lyric
func liftLambdasMsil(file: in SourceFile): SourceFile {
  val synths: List[Item] = newList()       // synthetic items
  val closures: Map[String, MClosureClass] = newMap()  // __lambda_i → closure
  
  // ... existing BFS collection logic ...
  
  // NEW: for each __lambda_i with captures:
  var idx = 0
  while idx < lambdaCount {
    val caps = cctx.lambdaCaptureNames.get("__lambda_" + toString(idx))
    if caps.count > 0 {
      val closureClass = synthesizeClosureClass(
        idx, caps, cctx.lambdaCaptureTypes.get("__lambda_" + toString(idx))
      )
      closures.add("__lambda_" + toString(idx), closureClass)
    }
    idx = idx + 1
  }
  
  // Register closures with codegen context for Phase 3
  cctx.lambdaClosureClasses = closures
  
  return fileWithNewItems
}

func synthesizeClosureClass(
  idx: Int,
  captureNames: List[String],
  captureTypes: List[MsilType]
): MClosureClass {
  val fields: List[MField] = newList()
  var fi = 0
  while fi < captureNames.count {
    fields.add(MField(
      flags = FDA_PUBLIC,
      name = captureNames[fi],
      fieldType = captureTypes[fi]
    ))
    fi = fi + 1
  }
  
  MClosureClass(
    className = "__closure_" + toString(idx),
    namespace = cctx.currentPkgName,
    fields = fields,
    useDefaultCtor = true
  )
}
```

#### Phase 3: Codegen (codegen.l)

**ELambda lowering change (lines 5536–5699):**

**Current:** Allocate `object[]`, populate with boxed captures, emit `ldftn` + `newobj Func`.

**New:**
1. Check if `cctx.lambdaClosureClasses` has an entry for this lambda
2. If **no captures** → keep as static (emit `ldftn` + `newobj Func(null)`)
3. If **captures exist**:
   - Emit `newobj __closure_<i>::.ctor()` (default constructor, no parameters)
   - For each capture: emit `dup`, load capture value, `stfld captureFieldName`
   - Emit `ldftn __lambda_<i>::Invoke`
   - Emit `newobj Func<object,…,object>::.ctor(object target, native int methodPtr)`

**Pseudocode:**
```lyric
case ELambda(lparams, lbody) -> {
  val caps = lambdaCaptureNamesMsil(fctx, lparams, lbody)
  val idx = cctx.lambdaTicker.count
  val lname = "__lambda_" + toString(idx)
  
  // Check for closure class
  val hasClosures = match mapGet(cctx.lambdaClosureClasses, lname) {
    case Some(cc) -> cc.fields.count > 0
    case None -> false
  }
  
  if hasClosures {
    // NEW: Construct closure instance with typed fields
    val closureClassName = "__closure_" + toString(idx)
    val closureType = cctx.lambdaClosureTypes.get(lname)  // MClosureClass
    
    // newobj __closure_<i>::.ctor()
    insns.add(MNewobjByName(className = closureClassName))
    
    // Initialize each field
    var capIdx = 0
    while capIdx < caps.count {
      insns.add(MDup)
      val capName = caps[capIdx]
      emitLoadVarMsil(fctx, insns, mapGet(fctx.slots, capName))
      // No boxing required — types match closure field types
      insns.add(MStfldByName(ownerFqn = closureClassName, fieldName = capName))
      capIdx = capIdx + 1
    }
    
    // Delegate construction: ldftn + newobj Func
    insns.add(MLdftnByName(ownerFqn = pkgName + "." + lname, methodName = "Invoke"))
    val ctorTok = buildFuncNCtorTok(cctx, lparams.count)
    insns.add(MNewobj(ctorToken = ctorTok))
    MObject
  } else {
    // UNCHANGED: Static lambda (no closure)
    insns.add(MLdNull)
    insns.add(MLdftn(methodToken = tok))
    insns.add(MNewobj(ctorToken = ctorTok))
    MObject
  }
}
```

**FuncCtx lowering change (lines 14603–14690):**

**Current:** Reserve slot 0 for `object[] __caps`, populate `captureNameToIndex`.

**New:**
1. If lambda **has closure class**: Don't reserve slot 0 for array
2. Closure fields are now **direct parameters** to `__lambda_<i>`'s method signature
3. Each captured variable's type comes from `closureClass.fields`
4. In EPath resolution: Load from closure parameter's field instead of `__caps[i]` array

**Pseudocode (lowerFuncMsil):**
```lyric
if lname.startsWith("__lambda_") {
  // Check if this lambda has a closure class
  val closureClassOpt = mapGet(cctx.lambdaClosureClasses, lname)
  
  match closureClassOpt {
    case Some(closureClass) if closureClass.fields.count > 0 -> {
      // Typed closure parameter
      val closureParamType = MClass(closureClass.className)
      fctx.params.add("__closure", closureParamType)
      fctx.slots.add("__closure", 0)
      fctx.types.add("__closure", closureParamType)
      
      // Register capture names → closure field names (for EPath)
      var fi = 0
      while fi < closureClass.fields.count {
        val fieldName = closureClass.fields[fi].name
        fctx.captureFieldName.add(fieldName, fieldName)  // new map
        fctx.captureFieldType.add(fieldName, closureClass.fields[fi].fieldType)
        fi = fi + 1
      }
    }
    case _ -> {
      // No closure (static lambda) or empty closure — no special handling
    }
  }
}
```

**EPath resolution change (lines 4600–4690):**

**Current:** Check `captureNameToIndex` to load from `__caps[i]`.

**New:**
1. Check `fctx.captureFieldName` for a closure field
2. If found: emit `ldarg 0` (the closure parameter), `ldfld fieldName`, return field type
3. Otherwise: use existing slot-based load

---

#### Phase 5: Lowering (lowering.l)

**New:** `lowerMClosureClass` function mirrors `lowerMRecord`.

```lyric
func lowerMClosureClass(
  closure: in MClosureClass,
  ctx: in LoweringCtx,
  pkgName: in String
): Unit {
  // Emit TypeDef row for __closure_<i>
  val typeName = closure.className
  val typeFlags = TDF_SEALED | TDF_BEFOREFIELDINIT | TDF_VISIBILITY_PUBLIC
  val tdRow = appendTypeDefRow(ctx.tables,
    typeFlags,
    closure.namespace,
    typeName,
    0x01000000 + boxTypeRef(ctx, MObject)  // base = System.Object
  )
  
  // Emit default .ctor (no parameters, calls Object::.ctor)
  val ctorFlags = MDA_PUBLIC | MDA_RTSPECIALNAME | MDA_SPECIALNAME
  val ctorSig = buildInstanceMethodSig([], MVoid)
  val ctorMrRow = appendMemberRefRow(ctx.tables,
    tdrTypeRef(ctx.trObject),
    ".ctor",
    ctorSig
  )
  val ctorBody = newMethodBody()
  emitLdarg_0(ctorBody)
  emitCall(ctorBody, ctorMrRow)
  emitRet(ctorBody)
  appendMethodDefRow(ctx.tables, ctorFlags, ".ctor", ctorSig, ctorBody)
  
  // Emit each field
  var fi = 0
  while fi < closure.fields.count {
    val field = closure.fields[fi]
    val fieldFlags = FDA_PUBLIC | FDA_INIT_ONLY  // immutable after construction
    val fieldSig = buildFieldSig(field.fieldType)
    appendFieldDefRow(ctx.tables, fieldFlags, field.name, fieldSig)
    fi = fi + 1
  }
  
  recordUserTypeDefRow(ctx, closure.namespace + "." + closure.className, tdRow)
}
```

**Integration into `lowerMPackage`:**

In the main package lowering loop (which currently processes `MPRecord`, `MPUnion`, etc.):

```lyric
match item {
  case MPClosureClass(closure) -> {
    lowerMClosureClass(closure, ctx, packageName)
  }
  case MPRecord(rec) -> { /* existing */ }
  case /* ... other cases ... */ -> { /* existing */ }
}
```

---

### 2.5 Deferred Complexity (v1.1+)

The following are **explicitly out of scope** for this implementation:

1. **Generic closure classes** — `__closure_0<T>` with type parameters
   - Requires `MClosureClass.generics: List[String]`
   - Field types become `MTypeVar` indices
   - Tied to generic lambda parameter inference (#1939)

2. **By-reference captures** — mutable locals hoisted to heap cells
   - Closure field holds `List[object]` cell reference
   - Requires `MClosureClass` field flags with `FDA_INIT_ONLY = false`
   - EPath unboxing logic for cell reads/writes

3. **Nested closures** — lambda inside lambda
   - Outer closure's parameter becomes a field in inner closure
   - Requires walk-back through multiple closure layers
   - Type propagation from nested to outer scopes

4. **Closure deduplication** — multiple lambdas capturing identical variable sets
   - Would reuse same closure class across several `__lambda_*` methods
   - Trade-off: code size vs. IL table bloat
   - Deferred pending empirical measurement

5. **Closure inheritance** — closure classes with user methods
   - Currently closures are data-only
   - Would require field + method synthesis
   - Tied to future lambda-in-type-body design

---

## 3. File-by-File Summary

### 3.1 `lyric-compiler/msil/codegen.l`

**Changes:**

| Line Range | Current | New | Purpose |
|---|---|---|---|
| 200–220 | Comment-only | Add context struct field | `cctx.lambdaClosureClasses: Map[String, MClosureClass]` |
| 5536–5699 | `ELambda` case | Branch on `hasClosures` | Closure construction vs. static path |
| 14603–14690 | Slot 0 reserved for `__caps` | Conditional closure param | Skip array slot if closure class exists |
| 16960–17000 | Synthetic IFunc creation | Also create `MClosureClass` | New `synthesizeClosureClass` helper |
| 17015–17100 | BFS expression collection | BFS for closures | Parallel closure discovery pass |

**New Functions:**
- `synthesizeClosureClass(idx, captureNames, captureTypes): MClosureClass`
- `collectClosuresFromLambdasBfs(lambdas): Map[String, MClosureClass]`

**Modified Signatures:**
- `liftLambdasMsil(file)` now returns `(file, closureClasses)`
- `codegenMsil(pkg, cctx)` accepts `cctx.lambdaClosureClasses`

### 3.2 `lyric-compiler/msil/lowering.l`

**Changes:**

| Line Range | Current | New | Purpose |
|---|---|---|---|
| 162 | MPackageItem union (end) | Add variant | `case MPClosureClass(closure: MClosureClass)` |
| 700–800 | (end of records) | New record | `record MClosureClass { … }` |
| 1800–1900 (est.) | `lowerMPackage` item dispatch | Add case arm | `case MPClosureClass(c) -> lowerMClosureClass(c, ctx, pkgName)` |
| (new) | — | New function | `lowerMClosureClass(closure, ctx, pkgName): Unit` |

**New Record Type:**
```lyric
pub record MClosureClass {
  className: String        // e.g. "__closure_0"
  namespace: String        // enclosing package
  fields: List[MField]     // closure fields (public, immutable)
  useDefaultCtor: Bool = true  // always emit parameterless .ctor
}
```

**New Function:**
```lyric
func lowerMClosureClass(
  closure: in MClosureClass,
  ctx: in LoweringCtx,
  pkgName: in String
): Unit { … }
```

### 3.3 `lyric-compiler/msil/bridge.l`

**Changes:**

| Line Range | Current | New | Purpose |
|---|---|---|---|
| 200 | Comment | Update | Note closure class synthesis in lambda-lifting phase |
| ~360 | `addPackageTokens(cctx, liftedFile, pkgName)` | Expanded | Register closure class TypeDefs alongside lambda methods |

**Context Impact:**
- `addPackageTokens` now needs to scan for and pre-assign TypeDef tokens to closure classes
- Existing MethodDef pre-scan extends to closure class `.ctor` methods

---

## 4. Test Cases

### 4.1 Non-Capturing Lambda

**Input:**
```lyric
func testNonCapturingLambda(): Func[Int] {
  val f: Func[Int] = { () -> 42 }
  f
}
```

**Expected IR (Phase 3):**
```
// No closure class synthesized
insns = [
  MLdNull,                                  // target = null (static)
  MLdftn(methodToken = <__lambda_0.Invoke>),
  MNewobj(ctorToken = <Func.ctor>)
]
```

**Expected IL:**
```
ldnull
ldftn <__lambda_0>::Invoke
newobj Func::.ctor
```

### 4.2 Single-Capture Lambda

**Input:**
```lyric
func testSingleCapture(): Int {
  val x = 42
  val f = { () -> x }
  f.Invoke()
}
```

**Expected IR (Phase 0 — Lambda Lifting):**
```
// Synthesized items:
cctx.lambdaClosureClasses["__lambda_0"] = MClosureClass(
  className = "__closure_0",
  namespace = "Test",
  fields = [MField(flags=FDA_PUBLIC, name="x", fieldType=MInt)]
)
```

**Expected IR (Phase 3 — Codegen):**
```
insns = [
  MNewobjByName(className = "__closure_0"),  // new __closure_0()
  MDup,
  MLdcI4(42),                                 // load captured value
  MStfldByName(ownerFqn="__closure_0", fieldName="x"),  // .x = 42
  MLdftnByName(ownerFqn="Test.__lambda_0", methodName="Invoke"),
  MNewobj(ctorToken = <Func.ctor>)
]
```

**Expected IL:**
```
newobj __closure_0::.ctor
dup
ldc.i4 42
stfld int32 __closure_0::x
ldftn object __lambda_0::Invoke(class __closure_0)
newobj class Func::.ctor(object, native int)
```

### 4.3 Multi-Capture Lambda

**Input:**
```lyric
func testMultiCapture(): Int {
  val x = 10
  val y = 32
  val f = { () -> x + y }
  f.Invoke()
}
```

**Expected Closure Class (Phase 5 — Lowering):**
```
class __closure_0 {
  public int32 x;
  public int32 y;
  
  public .ctor() {
    ldarg.0
    call System.Object::.ctor()
    ret
  }
}
```

**Expected Lambda Method (Phase 5):**
```
static object __lambda_0(class __closure_0 __closure) {
  ldarg.0              // load __closure param
  ldfld int32 __closure_0::x
  ldarg.0
  ldfld int32 __closure_0::y
  add
  box System.Int32
  ret
}
```

### 4.4 Nested Capture (Deferred)

**Input:**
```lyric
func testNestedCapture(): Func[Int] {
  val x = 10
  val outer = { () -> 
    { () -> x }  // inner lambda captures x
  }
  outer
}
```

**Status:** OUT OF SCOPE for Phase 1 — deferred to v1.1.

---

## 5. Risk Assessment

### 5.1 High Risk

1. **Closure class TypeDef pre-assignment** — closure classes must be allocated TypeDef tokens during the pre-scan phase (like lambda methods)
   - **Mitigation:** Extend existing `addPackageTokens` to discover and register closure classes
   - **Validation:** Closure token lookup in Phase 3 codegen must succeed

2. **Field initialization order** — fields must be initialized before delegate construction
   - **Mitigation:** Test with multi-capture lambdas; verify `dup` pattern maintains stack depth
   - **Validation:** MSIL verifier must accept all field-store sequences

3. **Cross-assembly closure references** — user code in one assembly calling a lambda from another
   - **Mitigation:** Closure classes are internal (no `public` namespace); only lambda method is callable
   - **Validation:** Closure class must not be exported to metadata

### 5.2 Medium Risk

1. **FuncCtx slot management** — removal of `__caps` slot requires careful re-indexing of remaining slots
   - **Mitigation:** Only skip slot 0 if closure class exists; non-capturing lambdas unaffected
   - **Validation:** Self-tests with mix of capturing/non-capturing lambdas

2. **Closure field type fidelity** — captured value types must exactly match closure field types
   - **Mitigation:** Propagate types from codegen Phase 3 to lowering Phase 5
   - **Validation:** MSIL verifier must accept all field stores/reads

3. **EPath resolution — capturing vs. closure parameters**
   - Existing `EPath` logic must distinguish between:
     - Closure-captured names (load from `__closure` field)
     - Regular local variables (load from slot)
     - Multi-level captures (walk closure chain — deferred to v1.1)
   - **Mitigation:** Add `fctx.captureFieldName: Map[String, String]` to track field names
   - **Validation:** Captured variable access must work in all lambda bodies

### 5.3 Low Risk

1. **Non-capturing lambdas** — should be unaffected
   - **Mitigation:** Explicit check `hasClosures == false` branches to existing static path
   - **Validation:** Rerun all existing lambda tests (should pass unchanged)

2. **Backward compatibility** — no public API changes at the Lyric level
   - **Mitigation:** Closure classes are compiler-synthesized, never exposed to user code
   - **Validation:** All existing `.l` files compile and run without modification

---

## 6. Edge Cases Identified

### 6.1 Scope: Capture Sets

**Case:** Overlapping captures in nested lambdas
```lyric
val x = 1
val outer = { () -> 
  val y = 2
  val inner = { () -> x + y }  // captures: x (outer), y (inner)
  inner
}
```

**Current Handling:** Each lambda gets its own `__lambda_<i>` with its own capture set.  
**New Handling:** Inner lambda's closure captures `y` directly; outer lambda's closure captures `x`. **Deferred** to nested-closures phase.

### 6.2 Mutable Captures (Cells)

**Case:**
```lyric
var x = 0
val f = { () -> x }
x = 5
f.Invoke()  // should return 5, not 0
```

**Current:** `x` hoisted to `List[object]` cell, captured by reference.  
**New (Phase 1):** Only by-value captures; mutable locals remain in hoisted cells.  
**Status:** Deferred to v1.1 per design constraint.

### 6.3 Generic Lambdas

**Case:**
```lyric
func mapWithCapture[T](f: (T) -> Int): Func[T, Int] {
  val scale = 10
  { (x: T) -> f(x) * scale }
}
```

**Current:** Parameters typed as `object`, unboxed on use.  
**New:** Would require `__closure_0<T>` with generic field.  
**Status:** Deferred to v1.1 (depends on #1939 generic HOF inference).

---

## 7. Validation Strategy

### 7.1 Unit Tests

1. **Non-capturing lambda** — verify no closure class synthesized
2. **Single-capture lambda** — verify closure class has one field
3. **Multi-capture lambda** — verify closure class has multiple fields in order
4. **Mixed lambdas** — multiple lambdas with overlapping captures
5. **Nested expressions** — lambda in argument position, return position, etc.

### 7.2 Regression Tests

- All existing `msil_self_test_m*.l` files should compile and run unchanged
- All existing self-tests in the compiler packages should pass

### 7.3 Integration Tests

- Full end-to-end `lyric build` on stdlib and example programs
- Verify JVM target unaffected (still uses different closure representation)

### 7.4 MSIL Verifier

- All synthesized closure classes and lambda methods must pass `peverify` checks
- No TypeLoadException at runtime
- No InvalidProgramException when invoking delegates

---

## 8. Implementation Timeline

### Phase 0 (Preparation)

1. Add `MClosureClass` record to `lowering.l`
2. Add `MPClosureClass` variant to `MPackageItem`
3. Add `cctx.lambdaClosureClasses` to codegen context

### Phase 1 (Core Synthesis)

1. Implement `synthesizeClosureClass` helper in codegen
2. Extend `liftLambdasMsil` to create closure classes
3. Extend `addPackageTokens` to register closure TypeDefs
4. Update `ELambda` codegen to construct closure instances
5. Update `lowerFuncMsil` lambda path for closure parameters
6. Implement `lowerMClosureClass` in lowering

### Phase 2 (Integration)

1. Wire closure class emission into `lowerMPackage`
2. Update `EPath` resolution for closure fields
3. Extend self-tests to exercise closure lambdas
4. Run full regression suite

### Phase 3 (Validation & Docs)

1. Verify MSIL output with `peverify`
2. Update decision log (#1877 backing decision)
3. Update `docs/09-msil-emission.md` with closure class strategy

---

## 9. Related Decisions & References

| Document | Relevance |
|---|---|
| D-progress-229 | Monomorphizer (Phase M5.2 stage 4) — lambdas remain non-generic in Phase 1 |
| D-progress-231 | Manifest bridge — closure classes co-register with lambdas |
| #1939 | Parameter typing for lambdas — by-value captures typed unambiguously |
| #1479 | Multi-level closures (deferred) |
| #1877 (this epic) | Strongly-typed lambda ABI |

---

## 10. Summary

**Closure class synthesis** replaces the generic `object[]` capture array with **synthesized, strongly-typed class instances**, eliminating boxing overhead and improving type safety. The implementation is localized to three files:

1. **codegen.l** — synthesize closure classes during lambda lifting; emit closure construction during codegen
2. **lowering.l** — emit closure class TypeDefs with typed fields during PE emission
3. **bridge.l** — extend token pre-assignment to closure classes

**Minimal scope** (non-generic, by-value, non-nested closures) allows shipping a production-quality implementation without deferring required features to follow-up PRs. Nested closures, generic closures, and by-reference captures are explicitly deferred to v1.1 with concrete tracking issues.
