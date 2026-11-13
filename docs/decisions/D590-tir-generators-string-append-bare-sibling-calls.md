# D590 - Generator bodies, `String +=`, bare sibling calls and `default()`/`wrapping*` build (docs/70 phase 3a, #8613)

**Status:** shipped; extends D366, D389.

## Context

The wide census (after D589) counted these as kinds the builder could not build: a branch conversion from `Unit` to the yield type (37 + 5 + 4 self-test sites, every one an `async func` whose body yields), an argument conversion from `Int`, `Bool` or `Double` to `String` (`s += 3.5`), a method call whose callee is not a member access (a bare call of a sibling method, 29 self-test and 18 ecosystem sites), and unresolved calls to `default()` and to the `wrapping*` integer methods.

## Decision

- **Generators.** A function whose body yields has `ret` = the type of each yielded value, and its body is the generator's code (a `Unit` block), not a value of `ret`. `TFnDecl` gains `isGenerator: Bool = false`; the builder sets it from `functionIsGenerator` (the checker's yield scan, now public) and does not coerce the body to `ret`; the verifier skips the `function body` rule for a generator. A backend that lowers a generator reads `isGenerator`; one that does not lowers nothing for it as before.
- **`String +=`.** `s += x` on a `String` appends `toString(x)`: a non-`String` value is wrapped in the `toString` builtin the way an interpolation part is, so no conversion node is invented.
- **Bare sibling calls.** `m(1)` inside a method of the same type is called on the enclosing method's `self` local; outside a method it is counted as `a bare method call outside a method`.
- **`default()` and `wrapping*`.** The checker records `default()` (with an expected type) and `<T>.wrappingAdd/Sub/Mul/Neg` as builtins under the call's `NodeId`, so TIR carries `IoBuiltin("default")` and `IoBuiltin("Byte.wrappingAdd")` and so on; they take their arguments unconverted, like `toString`.
- `argument conversion` now reports its site and the two types, as `branch conversion` does.

## Measured

`tir_build` 171 pass (five new cases: `String +=`, a generator, `default()`, `wrappingAdd` on a `Byte`, a bare sibling call; each verifies).
