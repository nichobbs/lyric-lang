# 46 — Const Patterns in Match Arms

**Status:** Shipped (D-progress-523; Q-MP-001 resolved in docs/06; codegen representation codified in D101)

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

In `typechecker_exprs.l`, const-pattern validation lives in
`checkConstRefPattern` (the shipped name; this sketch's `lowerPatternTest`
predates D101). `@NAME` resolves to a module-level `val`/`const`, and its
compile-time constant value is validated — but, per D101, the `PConstRef`
node is **retained** rather than rewritten to `PLiteral`; the sketch below
shows the validation logic, not a literal rewrite:

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

> **Implemented differently from this sketch — see D101.** The shipped type
> checker does *not* rewrite `PConstRef` to `PLiteral`; it validates the
> pattern and leaves the `PConstRef` node in the AST. `msil/codegen.l`'s
> `lowerPatternTestMsil` therefore has an explicit `PConstRef(constName)` arm:
> integer consts are matched with `ldc.i4`/`ceq` (value pulled from
> `cctx.constValues`); `String`/`Float`/`Long`/`Char` consts load the const's
> static field (`ldsfld` against `staticValTokens`) and compare with
> `Object.Equals` (strings) or `ceq`. The `case None ->` fall-through is a
> defensive `panic` guarded by `checkConstRefPattern` — it cannot fire for a
> type-checked program.

### Codegen (JVM)

> **Implemented differently from this sketch — see D101.** `jvm/codegen/03_match.l`
> has an explicit `PConstRef(constName)` arm that resolves the const's JVM type
> from `ctx.moduleVals` and emits a `getstatic` plus a type-appropriate
> comparison (`lcmp`/`if_icmpne` for `Long`, `dcmpl` for `Double`, `fcmpl` for
> `Float`, `equals` for reference types, `if_icmpne` for `Boolean`/`Char`/`Int`).
> Like the MSIL arm, the `case None ->` path is a defensive `panic`.

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
- [x] A rewritten `proto_main.l` (`lyric-proto/src/proto_main.l` `decodeStep`) uses `@WIRE_VARINT`/`@WIRE_FIXED64`/`@WIRE_LENGTH_DELIMITED`/`@WIRE_FIXED32` and compiles cleanly; the `lyric-proto` test suite (17 tests, incl. fixed32/fixed64/varint/length-delimited round-trips) passes (#3382, #3487).
- [x] No regressions in existing `EMatch` or pattern tests on MSIL: `const_pattern_self_test.l` (18) and `typechecker_self_test.l` (233, incl. the new T0068/T0069/T0072 and Bool-exhaustiveness const-pattern cases, #3485/#3488) pass via native `lyric test`. JVM parity is exercised by `const_pattern_self_test.l --target jvm` in CI.

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
- `lyric-compiler/lyric/parser/parser_ast.l` — `PConstRef(name: String)` variant in the `PatternKind` union (the AST node every other reference depends on)
- `lyric-compiler/lyric/parser/parser_exprs.l::parsePattern` — recognize `@Ident` and build `PConstRef` node
- `lyric-compiler/lyric/type_checker/typechecker_exprs.l::checkConstRefPattern` — validate a `PConstRef` arm against the scrutinee with T0068 (type mismatch), T0069 (non-constant val), T0071 (generic type), T0072 (name not a val/const); recurses through `POr`/`PParen`/`PTypeTest`/constructor/record sub-patterns
- `lyric-compiler/lyric/type_checker/typechecker_exprs.l::bindPatternTyped` — `PConstRef` arm introduces no bindings (a const pattern compares, it does not bind — same as `PLiteral`/`PWild`)
- `lyric-compiler/msil/codegen.l::lowerPatternTestMsil` — explicit `PConstRef` arm (see Codegen (MSIL) above; D101)
- `lyric-compiler/jvm/codegen/03_match.l` — explicit `PConstRef` arm (see Codegen (JVM) above; D101)
