# D367 - The call builder: built-in, indirect and direct calls, and the signature per call (docs/70 phase 3a, #8613)

**Status:** shipped (`buildCall` in `build_expr.l`); extends D366.

## Context

After D366 the builder census over the stdlib tests had a call (3212 nodes) at
the head of the kinds with no case. docs/70 §6.3 asks for a call's resolved
callee, its arguments in parameter order with defaults filled in, and the
conversions the checker accepts implicitly made explicit.

## Decision

1. `SymbolTable.callSigByNode` holds the `ResolvedSignature` a call to a declared
   function resolved against, keyed by the call's `NodeId`, beside
   `calleeByNode` (recorded where it is). The builder reads the parameters'
   names, types, modes and defaults from it, so no declaration lookup by
   `SymbolId` is needed for this slice.
2. A call whose `NodeId` is in `builtinByNode` builds as
   `Callee.Intrinsic(IoBuiltin(name))`, the receiver of a member built-in first,
   positional arguments only. A call in `indirectByNode` builds as
   `Callee.Indirect(fnValue)` with the callee expression built as the value.
3. A call to a declared, non-generic function named by a bare path builds as
   `Callee.Direct(sym, [])`. Arguments are placed by parameter: positional ones
   in order, named ones by name; each `in` argument is built and compared with
   the parameter's `Ty`. An equal type is used as is. A type the language
   widens implicitly (docs/01 §4.1: `Byte < Int < Long`, `Byte < UInt < ULong`,
   `Float < Double`) is wrapped in `XConvert(CvWiden(to))`. Any other
   difference is not guessed: it is an I0002 counted as "an argument
   conversion".
4. Arguments of every kind of call are checked against the parameter types and
   converted only along the implicit widenings, as a node of its own:
   - a call through a function value against the function type's parameters;
   - the element-taking members of `List`, `Map` and `Set` and the `slice`
     members against the receiver's type arguments (`xs.add(i)` on a
     `List[Long]` widens `i`);
   - any other built-in is built only when its arguments cannot need a
     conversion (the generic `println`, `print`, `toString`, `hashCode`, or no
     widenable primitive argument), else it is counted as "a built-in call with
     an argument the builder cannot check".
5. Named arguments take their parameter's slot first and the positional ones
   fill the free slots in order, as the checker pairs them; a parameter named
   twice is not built. TIR evaluates arguments in parameter order and the
   language in written order, so a call whose written order differs from
   parameter order is built only when every argument is plain (a literal or a
   name); otherwise it is counted as "a call whose named arguments reorder
   effects".
6. Every node the builder makes up has an id of its own, drawn above the ids
   `renumberNodeIds` hands out and shared by the functions of a file: a
   conversion, the `toString` call of an interpolation part, an interpolation
   text part, and a block with no node of its own (a branch, a loop body, the
   body of `unsafe`, a function body). TIR's `node-unique` rule holds.
7. Not built, each counted by its own kind: generic calls (they need the
   instantiation), a defaulted or missing argument (the default expression is
   the callee's, not the call's), `out` and `inout` arguments (they need
   places), method, constructor, member, package-qualified and extern calls, and
   a call the checker did not resolve.

## Census at this slice

Over `lyric-stdlib/tests/*_tests.l`: 242 of 1148 function bodies build (20
after D366). The kinds with no case, by nodes: a name that is not a local (720),
a match (484), a method, constructor or member call (478), a generic call (362),
an annotated binding (312), a member access (284), an assignment (171), an
index (144).

## Not covered

The kinds above, the instantiation table for generic calls (the builder reads
`genericCallTypeArgSites` by callee span, D366 notes), defaults, and the
conversions other than widening (distinct wrap and unwrap, range checks,
upcasts, host boxing).
