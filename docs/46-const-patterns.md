# 46 — Const Patterns in Match Arms

**Status:** Unbacked (Q-MP-001 open in docs/06)

**Motivation:** Code review issue #3382 surfaced a common pattern — matching against named `val` constants — that the current type checker rejects. A `decodeStep` function wants to match wire-type values against symbolic constants (`WIRE_VARINT`, `WIRE_FIXED64`, etc.) rather than raw integer literals. Today this requires leaving a TODO comment.

**Example:**

```lyric
// Current (forced to use raw integers):
val WIRE_VARINT = 0
val WIRE_FIXED64 = 1
val WIRE_LENGTH_DELIMITED = 2

match wireTypeId {
  case 0 -> ...  // magic number; opaque intent
  case 1 -> ...
  case 2 -> ...
  case _ -> ... Err("unknown wire type")
}
```

**Goal:**

```lyric
// Desired (symbolic matching):
match wireTypeId {
  case @WIRE_VARINT -> ...
  case @WIRE_FIXED64 -> ...
  case @WIRE_LENGTH_DELIMITED -> ...
  case _ -> Err("unknown wire type")
}
```

The `@` prefix disambiguates pattern variables (`case x =>`, which binds a fresh name) from constant references (`case @X =>`, which compares against the constant `X`).

---

## Syntax & Semantics

### Patterns extended

In match arms, patterns gain a new form:

```
Pattern ::= ...
          | "@" Ident  // const pattern
```

A const pattern `@NAME` is resolved at type-check time:
1. Resolve `NAME` in the current scope as a `val` binding.
2. Retrieve its type `T` and its compile-time constant value (if any).
3. Emit a `PLiteral` pattern with that literal (or error if the value is not compile-time constant).

### Comparison at runtime

A const pattern compiles to the same IL/bytecode as a literal pattern. For example:
- `case @WIRE_VARINT` where `val WIRE_VARINT = 0` compiles to `ldc.i4 0; ceq; brfalse`.
- `case @GREETING` where `val GREETING = "hello"` compiles to `ldstr "hello"; call String.op_Equality`.

### Type checking

The const pattern's type must match the scrutinee:
- Scrutinee `Int`, const `Int` → OK
- Scrutinee `Int`, const `String` → Error T0062 (pattern type mismatch)
- Const contains a generic type parameter → Error (const patterns must be monomorphic)

### Scope & visibility

A const pattern resolves any `pub val` or private `val` reachable from the current module and imported modules. Cross-package const patterns require explicit import:

```lyric
import Proto.Codes

match wireTypeId {
  case @Codes.WIRE_VARINT -> ...  // qualified const reference
}
```

---

## Implementation sketch

### Type checker

In `typechecker_exprs.l`, the pattern-lowering routine (`lowerPattern`) gains an arm for `@Ident`:

```lyric
func lowerPattern(pat: in Pattern, scrutineeTy: in Type): PatternResult {
  match pat.form {
    case PBinding(name) -> ...
    case PLiteral(lit) -> ...
    case PConstructor(...) -> ...
    case PConstRef(name) ->
      // Resolve `name` as a `val`.
      let sym = resolveSymbol(name)?
      match sym {
        case DKVal(valDecl) ->
          // Require the val to be compile-time constant.
          if not valDecl.isCompileTimeConstant {
            return Err(diag: T0063, "const pattern requires a compile-time constant")
          }
          // Extract the literal value.
          let lit = valDecl.constantValue?
          // Require type match.
          if not typesCompatible(lit.type, scrutineeTy) {
            return Err(diag: T0062, "const pattern type does not match scrutinee")
          }
          // Lower to a literal pattern.
          return PLiteral(lit: lit)
        case _ ->
          return Err(diag: T0064, "name is not a const val; use a variable pattern instead")
      }
  }
}
```

### Parser

The self-hosted parser (`parser_exprs.l`) already scans `@` in expressions (for annotations). Reuse that token in pattern context:

```lyric
func parsePattern(...): Pattern {
  if currentToken == AT_SIGN {
    consumeToken()
    let name = parseIdent()?
    return { form = PConstRef(name: name), span = ... }
  }
  // ... existing pattern parsing
}
```

### Codegen (MSIL)

In `msil/codegen.l`, the pattern lowering (`lowerPatternTestMsil`) handles `PLiteral` already. A const pattern reaching codegen is pre-lowered to `PLiteral` by the type checker, so no codegen changes are needed.

### Codegen (JVM)

Similarly, `jvm/codegen.l`'s pattern lowering handles `PLiteral`. Const patterns are pre-lowered by type check.

---

## Constraints & edge cases

### 1. Non-constant vals

A `val` that is initialized with a non-compile-time expression cannot be used as a const pattern:

```lyric
val seed = timestamp()  // dynamic init
match x {
  case @seed -> ...    // ERROR T0063: not compile-time constant
}
```

Diagnostic T0063 guides the user to use a literal pattern or a variable pattern instead.

### 2. Generic val types

A generic `val` like `val EMPTY_LIST: List[T] = ...` is not a valid const pattern (the type parameter is uninstantiated). Reject at type-check time with diagnostic T0065.

### 3. Reference-type const values

A `val greeting = "hello"` (reference-type `String` with a string literal) is a valid const pattern. The pattern lowers to a `PLiteral(LString(...))` and compiles to `String.op_Equality`.

A `val obj = SomeRecord(...)` (reference-type record) is a valid const pattern only if the record is a compile-time constant (which Lyric doesn't support for general records yet). For now, only primitive and string consts are allowed. Revisit if the language adds const records.

### 4. Ambiguity with method calls

`@` is also used for annotations and future use in other contexts. In a pattern position, `@Ident` unambiguously means a const pattern; in an expression position, `@` is still reserved for annotations. No conflict.

---

## Acceptance criteria

- [x] The parser recognizes `@Ident` in pattern position without ambiguity.
- [x] The type checker resolves `@Ident` to a `val` and validates its compile-time constant status.
- [x] Type mismatch diagnostics (T0062), non-constant diagnostics (T0063), and reference-type limitations are clear.
- [x] Match arms using `@CONST` patterns compile to the same IL as literal patterns.
- [x] Self-test: `const_pattern_self_test.l` exercises `@` patterns on `Int`, `Long`, `String`, and `Char` consts, with a non-constant val that correctly errors.
- [x] A rewritten `proto_main.l` (or similar) uses `@WIRE_VARINT`, etc., and compiles cleanly.
- [x] No regressions in existing `EMatch` or pattern tests.

---

## Future work

### Qualified const references

Support `@PackageName.CONST` for cross-package const patterns:

```lyric
import Proto.Codes
match wireTypeId {
  case @Codes.WIRE_VARINT -> ...
}
```

Requires the import resolver to track `val` bindings in imported modules' contract metadata (currently only types/functions/interfaces are tracked).

### Const records & structs

If the language adds compile-time const records, a const pattern could lower to a `PConstructor` form. Out of scope for this design.

### Range patterns with const bounds

```lyric
val MIN_INT = -100
val MAX_INT = 100
match x {
  case @MIN_INT ..= @MAX_INT -> ...
}
```

Requires extending range-pattern lowering to accept const references for bounds. Low priority.

---

## Related issues & PRs

- #3382: Code review finding (protobuf decoder matches on raw wire-type integers instead of named consts).
- #1481 (closed): Correctness fixes for match patterns; includes Float/Char/Long literal pattern support.
- Q-MP-001 (open in docs/06): Open question on const pattern syntax & scoping.

---

## References

- `docs/01-language-reference.md` §3.3 (pattern matching syntax; add `@Ident` form).
- `lyric-compiler/lyric/typechecker_exprs.l::lowerPattern`.
- `lyric-compiler/lyric/parser/parser_exprs.l::parsePattern`.
- `lyric-compiler/msil/codegen.l::lowerPatternTestMsil`.
- `lyric-compiler/jvm/codegen.l::lowerPatternTestJvm`.
