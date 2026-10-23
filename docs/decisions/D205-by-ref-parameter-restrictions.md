# D205 - Restrictions on `out`/`inout` parameters: no default, no `async`, no function value

**Status:** accepted, implemented (#8255, #8318, #8229, #8369)

## Context

D183 made an `out`/`inout` parameter refer to the caller's place itself while
the call runs. Three declaration and use shapes have no meaning under that
model, and each was accepted by the type checker and then failed, or silently
misbehaved, in a backend:

- A default value (`func bump(x: inout Int = 5)`): a call that omits the
  argument has no place to pass. dotnet reported T0120, the JVM J008 and
  native N0007 with a message about index expressions (#8255).
- An `async` function with an `out`/`inout` parameter: the state machine
  cannot hold a managed by-reference across a suspension, so dotnet copied the
  parameter and the write never reached the caller (and ilverify reported
  "found address of Int32"), while the JVM wrote it back and native refused
  with N0007 (#8318, #8229). docs/01 §5.2 only forbade the non-record
  value-type case and nothing enforced even that.
- A bare reference to a function with a by-reference parameter used as a
  value (`val f = bump`): dotnet reported an unrelated T0115, the JVM an
  internal J008, native N0007 (#8369). A function type has no by-reference
  parameters, so there is no type for the value.

## Decision

All three are rejected by the type checker, before codegen, with one
diagnostic worded the same on every target:

1. An `out`/`inout` parameter cannot have a default value: **T0182**, naming
   the parameter and its mode.
2. An `async` function, interface member, `impl` method or record method
   cannot declare an `out`/`inout` parameter: **T0183**. This is C#'s rule for
   `ref`/`out` on `async` methods. Copy-in/copy-out across the suspension was
   rejected: the callee could write after the caller has moved on, which is
   the aliasing D183 removes. The fix for the author is to return the new
   value (a tuple for several) or pass a record and change its `var` fields.
3. A function with an `out`/`inout` parameter is not a function value:
   **T0128**, the existing "cannot be used as a function value" code, now also
   raised for a function of the same package. Wrapping the call in a lambda
   over a `var` is the supported spelling.

Also, a non-`var` field is a place for neither an `out`/`inout` argument
(T0085, already enforced) nor an `inout` receiver: `h.p.reset()` where `p` is
not `var` on `H` is now **T0166** with the field named (#8215).

## Not decided here

#8289 asks for writes through an `in` parameter to be rejected. docs/01 §5.2
says the opposite on purpose: `in` forbids rebinding the parameter, not
mutating what it refers to, and D183's own example (`bump(x: inout Int, r: in
R)` writing `r.f`) relies on it. Changing that is a language redesign (a
read-only mode distinct from `in`), not a diagnostic, and is left to the issue.
