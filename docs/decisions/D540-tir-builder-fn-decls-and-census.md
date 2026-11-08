# D540 - The builder assembles TFnDecl and the I0003 census (docs/70 phase 3a, #8613)

**Status:** shipped (`buildFnDecl`, `build_syms.l`, `pipeReportVerifyCensus`); extends D399.

## Context

The builder produced a body per function but no `TFnDecl`, so nothing could run
`Lyric.Tir.Verify` over its output and the census counted only I0002. The first
real-file census (`lyric-stdlib/tests/collections_tests.l`: 1 of 13 bodies
built) also hid its cause: a `val xs: List[Int] = newList()` whose initialiser
the checker typed with a hole left `xs` undeclared, and every later use of `xs`
was counted as "a name that is not a local".

## Decision

1. `buildFnDecl` builds a function as a `TFnDecl`: its symbol, type parameters
   (names only; bounds are not converted yet), parameters as declared locals with
   their `TMode` and default expressions, the return type, `requires:` clauses as
   `preconds`, `ensures:` clauses as `postconds`, and the body. `buildFnBody` is
   the same build returning the body; it now builds the contracts too, so a
   clause the builder has no case for fails the body like any other expression.
2. The declarations a body reaches are recorded as `TSymEntry`s while it is
   built (`BuildEnv.syms`, `build_syms.l`): a direct, method or interface callee
   from the signature the checker recorded for the call (receiver first for a
   method), and a non-generic construction's fields from its constructor
   signature. A callee signature is converted in a context of its own, because
   the checker's binder keys are function names and must not replace the ones of
   the body being built. A signature that cannot be converted leaves no entry,
   and the verifier then reports the callee undefined. Each built function also
   gets the entry its own declaration implies.
3. `buildCensus` returns the built functions as a `TPackage`, and the
   `LYRIC_VERIFY_IR` census runs the verifier over it and prints the I0003 count
   per rule, then the first I0002 message of each body that did not build.
4. The checker settles an annotated initialiser (`settleInitType`): when the
   initialiser's own type is not closed and the annotation is, the node's
   recorded type is the annotation. A call with no evidence for its type
   arguments (`newList()`) then has a type, and the builder reads its
   instantiation back from that type (`genericArgsFromResult`) when
   `genericArgsByNode` has none.

## Measured

With `LYRIC_VERIFY_IR=1`, I0003 is 0 over every body the builder builds in
`string_tests.l` (11 of 13), `json_value_tests.l` (12 of 12), `collections_tests.l`
(4 of 13, was 1) and `core_tests.l` (2 of 10). The census found and this change
fixed three defects: `Lyric.Tir.Verify` required a `LocalId` to be unique across
the package where docs/70 §6.2 makes it dense within its function; the builder gave
an assignment expression and a synthesised `let` pattern the `NodeId` of their
statement; and no entry existed for named types or for union and enum cases
(`typeEntries`, `noteCaseSym`; a record's fields are converted under the record's
own binder).

## Not built yet

Entries for globals, interface methods of generic interfaces and generic
constructions; type-parameter bounds; `Self`. Over `collections_tests.l` the
largest I0002 kind is now a member access that is not a record field (collection
`count`, host properties), then the `for` loop and the untyped member and method
calls. The census names each so the order stays measured.
