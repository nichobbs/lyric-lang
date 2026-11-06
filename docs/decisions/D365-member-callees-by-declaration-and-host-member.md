# D365 - Method, interface and protected-type calls record their declaration; extern member calls record their host member (docs/70 phase 3a, #8613)

**Status:** shipped. Extends D361 (declared callees), D362-D364 (built-ins and function values).

## Context

After D364 the `LYRIC_VERIFY_IR=1` census over the stdlib tests listed calls to
the methods of records, `impl` blocks and interfaces (`feed.priceOf(s)`,
`self.stub.priceOf(s)`), the members of protected types, and the members of
`extern type`s (`stream.close()`, `T.new(..)`).

## Decision

1. A method pick resolves to a record-body, `impl` or interface method
   declaration, which no dot-named function stands for. `recordMethodCalleeNode`
   falls back to the resolver's id of the method declared at the signature's span
   (`symTableMethodDeclId`: the resolver's `SKMethod` declarations indexed by
   `<package>|<name>|<span>`). When two files of one package declare a method of that
   name at the same offsets, nothing is recorded rather than the wrong callee.
2. A call to a member of an interface or a protected type typed as a function
   records `Pkg::Type::member` (`recordTypeMemberCallee`); the builder reads the
   callee's kind (`Callee.Interface` or `Callee.Direct`) from the type's
   declaration.
3. A call to a member of an `extern type`, `T.new(..)` included, records an
   `ExternCallSite` (host type, receiver type arguments, member name, argument
   count) in `SymbolTable.externByNode`. `Lyric.Tir.Build` resolves the member
   from the host's metadata with these, as the checker did to type the call, so
   `HostMemberRef` is not duplicated in the checker.
4. `callCovered` counts a call covered by `calleeByNode`, `builtinByNode`,
   `indirectByNode` or `externByNode`.

## Not covered

Distinct-type factories (`T.from`, `T.tryFrom`), record `.copy`, a few calls on
computed callees (`<expr>`) and instance methods of host types reached through
a value whose type the checker leaves open; the instantiation, conversion and
argument-order tables; the expression builder.
