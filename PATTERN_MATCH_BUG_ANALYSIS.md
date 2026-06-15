# Pattern Matching Bug Analysis: Generic Union Case Constructor Type Arguments

## Executive Summary

A critical bug exists in `lyric-compiler/msil/codegen.l` where pattern matching on function parameters of generic union type (e.g., `Result[T, E]`) uses the **function's declared return type** to determine the context type arguments for generic union case constructors, instead of using the **scrutinee's actual type**. This causes incorrect TypeSpec construction and mismatched union case representations at runtime.

## Bug Location

**File:** `/home/user/lyric-lang/lyric-compiler/msil/codegen.l`

**Primary Issue Site:** Lines 8556–8582 in the `EPath` expression-lowering case (constructor calls)

**Related Functions:**
- `lowerPatternTestMsil` (line 7038)
- `lowerPatternBindMsil` (line 7633)
- `buildGenericCaseCtorTok` (line 20418)

## Data Flow: Pattern Matching vs. Constructor Calls

### Correct Flow: Function Argument Constructor Calls (Lines 8805–8851)

When a user writes a function call with a generic union constructor argument:

```lyric
func processResult(r: Result[Int, String]): Unit {
  someFunc(Ok(42))  // <- Constructor call inside function argument
}
```

The data flow is:

1. **Line 8811:** Retrieve the declared parameter type `pTy = Result[Int, String]`
2. **Line 8812–8827:** Extract the type arguments from the parameter: `pArgs = [Int, String]`
3. **Line 8820–8826:** **Set `fctx.contextHintTyArgs` explicitly** to `[Int, String]` via a save/clear/populate/restore pattern
4. **Line 8829:** Call `lowerCallArgMsil` with the context hint in place
5. Inside `lowerCallArgMsil`, when the nested `Ok(42)` is lowered via the `EPath` case (line 8556):
   - `fctx.contextHintTyArgs` is populated with `[Int, String]`
   - Lines 8557–8562 copy it into `outerCtxTyArgs`
   - Line 8658 calls `buildGenericCaseCtorTok(..., contextTyArgs=[Int, String], ...)`
   - The case constructor `Result_Ok<Int, String>` is built with the correct type arguments

**Result:** Correct TypeSpec and matching behavior.

### Broken Flow: Pattern Matching on Generic Parameter (Lines 6808–6809)

When a user writes pattern matching on a function parameter:

```lyric
func foo(x: Result[Int, String]): Boolean {
  match x {
    case Ok(v) -> true
    case Err(e) -> false
  }
}
```

The data flow is:

1. **Line 6808:** Call `lowerPatternTestMsil(cctx, fctx, armInsns, arm.pattern, scrutSlot, scrutTy, nextArmL)`
   - `scrutTy = Result[Int, String]` (the actual scrutinee type from the parameter)
   - Pattern matching does **not** set `fctx.contextHintTyArgs`

2. **Line 6809:** Call `lowerPatternBindMsil(cctx, fctx, armInsns, arm.pattern, scrutSlot, scrutTy)`
   - Correctly passes `scrutTy = Result[Int, String]`
   - But **`fctx.contextHintTyArgs` is still empty** from the match setup

3. Inside `lowerPatternBindMsil` (line 7673), when binding the `Ok(v)` pattern:
   - The pattern's `PConstructor` case is matched (line 7673)
   - The case class type is determined from `scrutTy` (lines 7675–7680): `baseCls = "Std.Core.Result"`
   - But `scrutTy` information is **not propagated to `contextHintTyArgs`**

4. Later, when the bound field value is used in the arm body, if there's a nested constructor call:
   - The function context still has empty `contextHintTyArgs` from pattern-match setup
   - The data flow follows the "Broken" path through EPath (line 8556)

### The Bug: EPath Fallback (Lines 8556–8582)

When `EPath` is lowering a union constructor call and needs to determine `contextTyArgs`:

```lyric
val outerCtxTyArgs: List[MsilType] = newList()
if fctx.contextHintTyArgs.count > 0 {
  // Lines 8557–8562: Copy context hints IF SET
  var hci = 0
  while hci < fctx.contextHintTyArgs.count {
    outerCtxTyArgs.add(fctx.contextHintTyArgs[hci])
    hci = hci + 1
  }
} else {
  // Lines 8564–8581: FALLBACK — THIS IS THE BUG
  match fctx.declaredRetTy {
    case MGenericInst(_, _, retArgTys) -> {
      var rci = 0
      while rci < retArgTys.count {
        outerCtxTyArgs.add(retArgTys[rci])  // <- Uses function's return type!
        rci = rci + 1
      }
    }
    case MGenericInstByName(_, retArgTys) -> {
      // Same fallback
    }
    case _ -> ()
  }
}
```

**The Problem:**

- When `fctx.contextHintTyArgs` is empty (not set during pattern matching), the code falls back to `fctx.declaredRetTy` (the function's declared return type)
- For pattern matching on a parameter, this is **wrong**. Example:

  ```lyric
  func foo(x: Result[Int, String]): Boolean {
    match x {
      case Ok(v) -> Some(v)  // <- Nested Some(v) call
    }
  }
  ```

  - Scrutinee type: `Result[Int, String]` (type argument: `[Int, String]`)
  - Function's declared return type: `Boolean`
  - Fallback uses `[]` (no type args from Boolean)
  - Nested `Some(v)` is constructed without context type args
  - Result: `Some<object>` instead of the implied type

- For a more concrete bug manifestation:

  ```lyric
  func processError(e: Result[Int, String], handler: (String) -> Unit): Unit {
    match e {
      case Err(msg) -> handler(msg)
      case Ok(_) -> ()
    }
  }
  ```

  - The function returns `Unit`
  - `contextTyArgs` falls back to `[]` (Unit has no type arguments)
  - Pattern matching on `Result[Int, String]` should provide `[Int, String]`
  - But the fallback produces wrong context type arguments

## The Context Type Argument Chain: Where It Should Come From

For pattern matching to work correctly, the context type arguments must be **derived from the scrutinee's type**, not the function's return type.

### Current (Wrong) Derivation:

```
lowerPatternTestMsil/lowerPatternBindMsil (line 6808–6809)
  → scrutTy = Result[Int, String]  (PASSED IN, CORRECT)
  → fctx.contextHintTyArgs is NOT SET
  → Later in buildGenericCaseCtorTok (line 8556):
    → No hint available
    → Falls back to fctx.declaredRetTy = Boolean
    → contextTyArgs = []  (Boolean has no type arguments)
    → buildGenericCaseCtorTok uses wrong type arguments
```

### Required (Correct) Derivation:

```
lowerPatternTestMsil/lowerPatternBindMsil (line 6808–6809)
  → scrutTy = Result[Int, String]  (PASSED IN, CORRECT)
  → SHOULD SET fctx.contextHintTyArgs from scrutTy
    → Extract type arguments: [Int, String]
    → Set contextHintTyArgs = [Int, String]
  → Later in buildGenericCaseCtorTok (line 8556):
    → contextHintTyArgs is populated
    → contextTyArgs = [Int, String]  (CORRECT)
    → buildGenericCaseCtorTok constructs case classes with correct type arguments
```

## Code Flow Trace: Pattern Matching Path

### Entry Point (Line 6808–6809):

```lyric
lowerPatternTestMsil(cctx, fctx, armInsns, arm.pattern, scrutSlot, scrutTy, nextArmL)
lowerPatternBindMsil(cctx, fctx, armInsns, arm.pattern, scrutSlot, scrutTy)
```

**Arguments passed:**
- `scrutSlot`: Stack slot holding the scrutinee value
- `scrutTy`: The scrutinee's MSIL type (e.g., `MGenericInst(..., "Std.Core.Result", [MInt, MString])`)

**What happens:** These functions emit pattern-matching IL code but **do not modify `fctx.contextHintTyArgs`**.

### Inside Pattern Binding (Line 7673–7767):

When a `PConstructor` pattern is bound:

```lyric
case PConstructor(head, fields) -> {
  val caseName = lastSegmentMsil(head)
  val baseCls = match scrutTy {
    case MClass(cls) -> cls
    case MGenericInst(_, fqn, _) -> fqn
    case MGenericInstByName(fqn, _) -> stripGenericArity(fqn)
    case _ -> ""
  }
```

**The scrutinee type is examined (line 7675–7680):** `scrutTy` is matched to extract its base class and type arguments.

**But the context is not set:** The function never says "now that we know we're binding a `Result[Int, String]`, set the context type arguments for nested constructor calls to `[Int, String]`."

### When a Nested Constructor Is Built (Line 8556–8582):

If the matched field is later used in a constructor call inside the arm body:

```lyric
case Ok(v) -> Some(v)  // <- Ok binds v, then Some(v) constructs
```

The `Some(v)` call flows through `EPath`, which queries `contextHintTyArgs`:

- **Line 8557:** Checks `if fctx.contextHintTyArgs.count > 0`
- **Result:** False (never set during pattern matching)
- **Line 8564–8581:** Falls back to deriving from `fctx.declaredRetTy`

**Consequence:** The fallback is used, which is wrong.

## Comparison: Constructor Call Path (How It Works Correctly)

Compare with function-argument constructor calls (lines 8805–8851):

```lyric
// When lowering a function call with a generic-typed parameter:
val pTy = if i < callParamTys.count { callParamTys[i] } else { MObject }
match pTy {
  case MGenericInst(_, _, pArgs) -> {
    val savedHints: List[MsilType] = newList()
    // SAVE current hints
    var sh = 0
    while sh < fctx.contextHintTyArgs.count {
      savedHints.add(fctx.contextHintTyArgs[sh])
      sh = sh + 1
    }
    // CLEAR hints
    while fctx.contextHintTyArgs.count > 0 {
      fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
    }
    // POPULATE with parameter type args
    var ph = 0
    while ph < pArgs.count {
      fctx.contextHintTyArgs.add(pArgs[ph])  // <- EXPLICIT SET
      ph = ph + 1
    }
    // Lower the argument with hints in place
    val _ = lowerCallArgMsil(cctx, fctx, insns, callArgs[i])
    // RESTORE saved hints
    while fctx.contextHintTyArgs.count > 0 {
      fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
    }
    var rh = 0
    while rh < savedHints.count {
      fctx.contextHintTyArgs.add(savedHints[rh])
      rh = rh + 1
    }
  }
}
```

**Key difference:** This code **explicitly sets `contextHintTyArgs`** from the parameter type before lowering arguments. Pattern matching should do the same.

## manifestation: Generic Union Case Constructor Bug

When `buildGenericCaseCtorTok` is called with wrong `contextTyArgs`:

**Line 20418–20451:**

```lyric
func buildGenericCaseCtorTok(
  cctx: in CodegenCtx,
  ctorKey: in String,
  argTypes: in List[MsilType],
  contextTyArgs: in List[MsilType],  // <- WRONG when pattern matching
  outParentTy: in List[MsilType],
  insns: in List[MInsn],
): Int {
  val nTypeParams = match mapGet(cctx.caseTypeParamCount, ctorKey) { case Some(n) -> n; case None -> return 0 }
  // ... (field metadata lookup)
  val typeArgs: List[MsilType] = newList()
  var tpi = 0
  while tpi < nTypeParams {
    var argFoundTy: MsilType = MObject
    // ... (search argTypes for type inference)
    var foundTy: MsilType = MObject
    if tpi < contextTyArgs.count and contextTyArgs[tpi] != MObject {
      // If context provides a type, use it
      val ctxTy = contextTyArgs[tpi]
      // ...
      foundTy = ctxTy
    }
    if foundTy == MObject {
      foundTy = argFoundTy
    }
    typeArgs.add(foundTy)  // <- WRONG typeArgs added
    tpi = tpi + 1
  }
  // ... (builds MNewobjGenericCase with wrong typeArgs)
  insns.add(MNewobjGenericCase(typeRefRow = caseRefRow, typeArgs = typeArgs, ctorParams = ctorPs))
```

**Consequence:**

- When `contextTyArgs` is empty or wrong (from the function's return type instead of the scrutinee's type)
- The inferred `typeArgs` are incorrect
- `MNewobjGenericCase` is emitted with the wrong TypeSpec
- The union case constructor builds a mismatched type (e.g., `Ok<object>` instead of `Ok<Int>`)
- Runtime representation doesn't match scrutinee, causing match failures or type errors

## Concrete Example of Failure

```lyric
func processResult(x: Result[Int, String]): Boolean {
  match x {
    case Ok(value) -> {
      // Here, we want to construct Option[Int] from the value
      match Option.Some(value) {
        case Some(v) -> v > 0
        case None -> false
      }
    }
    case Err(_) -> false
  }
}
```

**What should happen:**

1. Pattern match on `Result[Int, String]` parameter
2. Bind `value: Int` from `Ok` case
3. Construct `Some(value)` with context: `[Int]` (from the matched union)
4. Pattern match on `Option[Int]` discriminates correctly

**What actually happens (bug):**

1. Pattern match on `Result[Int, String]` parameter
2. `contextHintTyArgs` is not set
3. Construct `Some(value)`:
   - Falls back to `fctx.declaredRetTy = Boolean`
   - `contextTyArgs = []` (no type args from Boolean)
   - Constructs `Some<object>` instead of `Some<Int>`
4. Pattern match on `Some<object>` may not match the expected type, or worse, silently accepts wrong values

## Summary of the Bug

| Aspect | Correct (Function Args) | Broken (Pattern Matching) |
|--------|-------------------------|--------------------------|
| **Scrutinee type** | `Result[Int, String]` | `Result[Int, String]` (correct) |
| **How context is set** | Explicitly from parameter type via lines 8820–8826 | **Not set at all** |
| **Fallback source (line 8564)** | Never reached (hint is set) | `fctx.declaredRetTy` (function return type) |
| **Example result type** | `Result[Int, String]` → context `[Int, String]` | `Boolean` → context `[]` |
| **Constructor built** | `Ok<Int>` (correct) | `Ok<object>` (wrong) |

## Files to Examine for Implementation

1. **`lyric-compiler/msil/codegen.l` (line 6808–6809):** Pattern matching entry point — needs to set `contextHintTyArgs` from `scrutTy`
2. **`lyric-compiler/msil/codegen.l` (lines 7038–7492):** `lowerPatternTestMsil` — check if it can propagate type info
3. **`lyric-compiler/msil/codegen.l` (lines 7633–7865):** `lowerPatternBindMsil` — where context should be set
4. **`lyric-compiler/msil/codegen.l` (lines 8556–8582):** The fallback logic that applies the bug
5. **`lyric-compiler/msil/codegen.l` (lines 8805–8851):** Reference implementation showing correct `contextHintTyArgs` setup

## Key Data Structures

- **`FuncCtx.contextHintTyArgs: List[MsilType]`** — Stack of type arguments for nested generic constructor calls. Pattern matching must populate this from the scrutinee's type.
- **`FuncCtx.declaredRetTy: MsilType`** — The function's declared return type. Used as fallback when hints are missing, but is wrong for pattern matching.
- **`scrutTy: MsilType`** — The scrutinee's actual type (e.g., `MGenericInst(..., "Std.Core.Result", [MInt, MString])`). Contains the correct type arguments.
