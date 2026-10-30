# D271 - `Unit` is an ordinary type with exactly one value, on every target

**Status:** accepted, implemented (#8236, #8266). Decided by the repo owner 2026-10-23.

## Context

`Unit` was lowered as "no value": a `func f(): Unit` has a void return, an
expression of type `Unit` leaves nothing on the stack, and a `Unit`-typed
binding was a name with no storage. That works while nothing needs to store a
`Unit`, and fails the moment something does. Each backend failed differently:

- **dotnet** emitted a `void` parameter (`TypeLoadException`, ilverify
  `StackUnexpected`) or an `object` where a `void` was expected
  (`InvalidProgramException`);
- **the JVM** failed with J008 (stackmap underflow) on a `Unit` argument and
  with "no matching method `ArrayList.add(V)`" for a `List[Unit]`;
- **native** declared `void %u` parameters and passed `void undef` arguments,
  which clang rejects.

The triggering shapes were a generic function instantiated at `T = Unit`
(#8236, including a generic function returning a lambda whose result is `T`)
and a parameter of type `Unit` in any mode, on a free function, a record
method, a protected entry or an interface method (#8266). The issues offered
two ways out: reject `Unit` parameters and `T = Unit` in the type checker, or
materialise `Unit` as a value.

## Decision

`Unit` is an ordinary type. It has exactly one value, `()`. That value is
materialised wherever a parameter, field, local, return slot or type argument
needs storage, on every target, and a program cannot tell the targets apart:

- `Result[Unit, E]`, `Option[Unit]`, `List[Unit]`, a generic record with a
  `Unit` field, a generic function at `T = Unit`, a lambda that accepts or
  returns `Unit`, a function value of type `(Unit) -> Unit` and a parameter
  `x: in Unit` all work.
- The `Unit` argument expression of a call is still evaluated, once, for its
  effects.

The calling convention of `func f(): Unit` is unchanged: it keeps its void
return where nothing observes the result. Only an observed result pays. An
expression of type `Unit` that is stored, passed, captured or returned through
a generic or first-class slot yields the unit value there.

### Representation per backend

| Target | A slot that holds `Unit` | An unobserved `Unit` |
|---|---|---|
| dotnet (MSIL) | `object`, holding `null` (parameter, field, closure capture, generic argument) | no stack value; a `Unit` call used as a value is followed by `ldnull` |
| JVM | `Ljava/lang/Object;`, holding `null` | no stack value; `aconst_null` where a value is consumed |
| native | `i8` placeholder; a `List`/`Map`/`Task` slot is the zero word | the `NVoid` type; no SSA value |

A `Unit` binding with no storage stays a *virtual* binding (it has no local
slot and reads as "no value"), and every consumer that needs a value
materialises one. Because all three representations carry no information, a
`Unit` is never `null`-checked and has no identity.

The single rule behind the dotnet and JVM representations is the one the
backends already used for a `Unit` payload in `Result[Unit, E]` (a generic
argument encodes as `object`): this decision applies it to every other
storage position.

## Rejected alternative

Rejecting `Unit` parameters and `T = Unit` in the type checker. It would keep
the lowering as it was, but every generic container and every higher-order
function would need a special case for `Unit` (`Task[Unit]`, `Result[Unit, E]`
and `spawn` of a `Unit`-returning call are already legal and common), and a
generic function could not be written once for all `T`.

Dropping a `Unit` parameter from the signature (the other option in #8266) was
also rejected: erased generics call a first-class `Unit`-taking function with
the unit value, so the parameter must exist in the function's ABI.

## Consequences

- docs/01 §2.1 states the rule; docs/09 (MSIL), docs/18 (JVM) and
  `native/plan/03-type-mapping.md` record the representation.
- `lyric-compiler/lyric/unit_value_self_test.l` pins the behaviour on dotnet,
  the JVM and native.
- No diagnostic is added: nothing that type checked before is rejected.
