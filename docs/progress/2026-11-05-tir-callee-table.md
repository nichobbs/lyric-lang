# A callee table keyed by the call's NodeId (docs/70 phase 3a, D361)

`SymbolTable.calleeByNode` records the `SymbolId` a call to a declared function
resolved to, beside the span-keyed `calleeSites` the backends read. The
`LYRIC_VERIFY_IR=1` census now also counts calls with no recorded callee, which
is the work list for the remaining routes (built-ins, constructors, methods,
interface methods, function values, extern members). See D361.

Method calls (including UFCS dot-named picks) record their callee too, and the census names each uncovered call's line and column.

Record and union-case constructor calls record their callee too, and the census prints the uncovered callees by frequency, which ranks the remaining routes (collection members, then the built-ins).
