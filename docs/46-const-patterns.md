# 46 — Const Patterns in Match Arms

**Status:** Shipped (D-progress-523; Q-MP-001 resolved in docs/06)

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
          | "@" Ident  // const pattern: @CONST_NAME references a compile-time constant
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
- Scrutinee `Int`, const `String` → Error T0068 (pattern type mismatch)
- Const contains a generic type parameter → Error (const patterns must be monomorphic)

### Scope & visibility

A const pattern resolves any `pub val` or private `val` reachable from the current module and imported modules. In Phase 3+ v1, only unqualified const references are supported; qualified refs (`@Package.CONST`) are deferred to future work.

---

## Implementation sketch

### Type checker

In `typechecker_exprs.l`, the pattern-lowering routine (`lowerPatternTest`) gains an arm for `@Ident` const patterns. During type checking, `@NAME` resolves to a module-level `val`, and its compile-time constant value is validated:

```lyric
// In lowerPatternTest (comparison-side pattern lowering):
case PConstRef(name) ->
  // Resolve `name` as a `val`.
  let sym = resolveSymbol(name)?
  match sym {
    case DKVal(valDecl) ->
      // Require the val to be compile-time constant.
      if not valDecl.isCompileTimeConstant {
        diag.add(errorDiagnostic("T0069", "const pattern requires a compile-time constant val", pattern.span))
        return MError
      }
      // Extract the literal value.
      let lit = valDecl.constantValue?
      // Require type match with scrutinee.
      if not typesCompatible(lit.type, scrutineeTy) {
        diag.add(errorDiagnostic("T0068", "const pattern type " + renderType(lit.type) + 
          " does not match scrutinee type " + renderType(scrutineeTy), pattern.span))
        return MError
      }
      // Lower to a literal pattern comparison (no binding).
      return lowerLiteral(lit)  // PLiteral arm in existing code
    case _ ->
      diag.add(errorDiagnostic("T0072", "name is not a val; use a variable pattern or const reference", pattern.span))
      return MError
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
  case @seed -> ...    // ERROR T0069: not compile-time constant
}
```

Diagnostic T0069 guides the user to use a literal pattern or a variable pattern instead.

### 2. Generic val types

A generic `val` like `val EMPTY_LIST: List[T] = ...` is not a valid const pattern (the type parameter is uninstantiated). Reject at type-check time with diagnostic T0071.

### 3. Reference-type const values

A `val greeting = "hello"` (reference-type `String` with a string literal) is a valid const pattern. The pattern lowers to a `PLiteral(LString(...))` and compiles to `String.op_Equality`.

A `val obj = SomeRecord(...)` (reference-type record) is a valid const pattern only if the record is a compile-time constant (which Lyric doesn't support for general records yet). For now, only primitive and string consts are allowed. Revisit if the language adds const records.

### 4. Ambiguity with `@` in annotation position and existing pattern use

`@` is already used in two other contexts:
1. **Annotations**: `@derive`, `@test_module`, `@axiom` in declaration and expression positions. These never appear in patterns.
2. **Binding patterns**: The existing `BindingPattern = IDENT [ '@' PrimaryPattern ]` form (the `x @ Foo(_)` pattern) allows binding a variable while destructuring.

The new const pattern `@Ident` introduces a third `@` use, but both are unambiguous:
- Const pattern: `@NAME` appears directly in a match arm, refers to a `val` binding, and is fully qualified by context (patterns).
- Binding pattern: `x @ PATTERN` always has a variable name before `@`, so the parse is distinct. Const patterns never have a preceding identifier.
- Annotations: Appear in declaration/expression contexts, never in pattern destructuring position.

No parse conflict.

---

## Acceptance criteria

These are implementation checkpoints for Phase 3+ work:

- [x] `docs/grammar.ebnf` updated: `PrimaryPattern` (or `Pattern`) includes `"@" Ident` alternative as `ConstPattern`.
- [x] `docs/01-language-reference.md` §4.2 updated: match-pattern syntax expanded with const pattern form, semantics, and examples.
- [x] `book/chapters/` CLI/chapter references updated: const patterns documented and example works end-to-end.
- [x] `docs/10-bootstrap-progress.md` updated: const-pattern implementation milestone recorded (D-progress-523).
- [x] The self-hosted parser recognizes `@Ident` in pattern position without ambiguity (no conflicts with annotations or binding patterns).
- [x] The type checker resolves `@Ident` to a `val`, validates compile-time constant status (T0069), type match (T0068), and val existence (T0072).
- [x] Generic val types rejected with diagnostic T0071.
- [x] Match arms using `@CONST` patterns compile to the same IL/bytecode as literal patterns (MSIL: `constValues` lookup + `ldc.i4/ceq` or `ldsfld/ceq`; JVM: `getstatic` + type-appropriate comparison).
- [x] Self-test: `const_pattern_self_test.l` exercises `@` patterns on `Int`, `Long`, `String`, `Char`, `Bool`, and `Float` consts.
- [ ] A rewritten `proto_main.l` (or similar) uses `@WIRE_VARINT`, etc., and compiles cleanly.
- [ ] No regressions in existing `EMatch` or pattern tests on both MSIL and JVM backends.

---

## Future work

### Qualified const references

Phase 3+ v2 or later: support `@PackageName.CONST` for cross-package const patterns:

```lyric
import Proto.Codes
match wireTypeId {
  case @Codes.WIRE_VARINT -> ...
}
```

Requires extending contract metadata to track `val` bindings from imported modules (currently only types/functions/interfaces are tracked).

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

**Documentation to update:**
- `docs/grammar.ebnf` — add `ConstPattern = "@" Ident` to `PrimaryPattern` alternatives (Phase 0 deliverable #4)
- `docs/01-language-reference.md` §3.3 — pattern matching syntax; add const pattern form, semantics, and examples
- `book/chapters/01-getting-started.md` — toolchain table may need const-pattern version notes
- `book/chapters/appendix-b-quick-reference.md` — pattern-matching reference section
- `docs/10-bootstrap-progress.md` — record const-pattern implementation milestone

**Implementation files:**
- `lyric-compiler/lyric/type_checker/typechecker_exprs.l::lowerPatternTest` — add `PConstRef` arm with T0068, T0069, T0071, T0072 diagnostics
- `lyric-compiler/lyric/type_checker/typechecker_exprs.l::lowerPatternBind` — add `PConstRef` arm (returns `PError`; const patterns don't bind)
- `lyric-compiler/lyric/parser/parser_exprs.l::parsePattern` — recognize `@Ident` and build `PConstRef` node
- `lyric-compiler/msil/codegen.l::lowerPatternTestMsil` — no changes (const patterns are pre-lowered to `PLiteral` by type check)
- `lyric-compiler/jvm/codegen.l::lowerPatternTestJvm` — no changes (const patterns are pre-lowered to `PLiteral` by type check)
