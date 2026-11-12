# D584 - A constructor pattern whose head is no case of the scrutinee's type is T0129 (#9024)

**Status:** shipped; extends the T0129 case check (docs/01 patterns).

## Context

`case P(0, b)` against a record `P`, and `case Nope(k)` against a union with no case `Nope`, type-checked with no diagnostic: `unionCaseSymbolForScrutinee` found no case, the sub-patterns were bound at an error type, and the arm body's use of `b` or `k` failed later with `I0001` ("this EPath expression has no type and no error was reported"). The language reference defines constructor patterns for union and enum cases only; a record is destructured with a record pattern, `P { x = 0, y }`. No positional record pattern is specified, so none is added: accepting `P(0, b)` would extend the language, which is the owner's call.

## Decision

- `bindPatternTyped` reports T0129 when a constructor pattern resolves to no case and nothing else was reported for it, and the scrutinee is a declared type. The message names the head and the scrutinee's type, and when the head names a record it points to the record pattern.
- A scrutinee whose type is unknown or open (a type variable, `Self`, a nullable, an error type) is left alone, as the existing T0129 checks do. A `val`/`for` binding pattern (`bindingOnly`) is not checked.
- If a positional record pattern is wanted, it is a language addition with its own decision; this one only removes the silent acceptance.

## Measured

`typechecker` 1148 pass, with three new cases: a record head and an unknown head are T0129, and valid record and case patterns are not.
