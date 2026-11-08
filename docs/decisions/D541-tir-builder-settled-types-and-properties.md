# D541 - Expected types settle holes; property reads, generic cases and explicit type arguments (docs/70 phase 3a, #8613)

**Status:** shipped; extends D540.

## Context

After D540 the stdlib test census showed what stopped bodies from building:
expressions the checker types with a hole because they carry no evidence for a
type argument (`newList()`, a bare `None`, `[]`) although a context fixes it;
collection and string property reads; generic union-case constructions; and
calls written `f[A, B](x)`.

## Decision

1. `inferExprExpected` records the expected type as the node's type when the
   inferred type mentions the hole (`typeMentionsHole`) and the expected type is
   closed. This replaces D540's `settleInitType`, which did it for annotated
   initialisers only; it now covers returns, tail expressions and any other
   position typed against an expected type. A mismatch is still diagnosed by the
   ordinary check, and the builder runs only on a clean check.
2. An argument the checker still typed with a hole (`pick(Nothing, 7)`, `join(",", [])`)
   takes its parameter's type, once the call's other arguments have fixed it
   (`BuildEnv.settled`, `settleArg`).
3. A collection's `count` and a string's `length` are built-in property reads,
   `XCall(Intrinsic(IoBuiltin("List.count")), [recv])` and likewise `Map.count`,
   `Set.count`, `String.length`, `slice.length`, `array.length`. A user type
   named `List` is not the stdlib's (checked by declaring package).
4. A union-case construction records its constructor signature when its result
   type is closed, generic or not (`Some(value = 42)` as `Option[Int]`); the
   case's `TSymEntry` is the generic one (`noteCaseSym`), so the verifier
   substitutes the instance.
5. The callee of `f[A, B](x)` is recorded by call node (`calleeByNode`,
   `callSigByNode`) from `checkExplicitTypeArgCall`. It is not recorded in
   `calleeSites`: backends look a call up by the callee's site, which this
   callee never had, and this change leaves their behaviour as it was.
6. The test that pinned a bare generic nullary case as counted
   ("... is counted, not guessed") now asserts the instantiation the expected type
   fixes: the case it described is now built, and it was never a guess, since the
   declared return type is the evidence.

## Measured

`LYRIC_VERIFY_IR=1`: `collections_tests.l` 13 of 13 bodies built (was 4),
`json_value_tests.l` 12 of 12, `string_tests.l` 12 of 13 (was 11),
`core_tests.l` 5 of 10 (was 2); I0003 stays 0 over everything built.
