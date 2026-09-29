# Memoise the stdlib collection type ids in the type checker (#7765)

`isStdCollectionsHostType` decides whether a type is the stdlib `List`, `Map`,
`MapKeyCollection` or `MapValueCollection` by the type's identity (#7737). It
did this with `symTableTryFindInPackage(tbl, "Std.CollectionsHost", name)` at
every use, which is a backward linear scan of the whole symbol table. The
checker runs it on every iterated collection, every indexed receiver, every
bracket literal checked against a `List` parameter or field, every
`slice.toList()`, and every stdlib-collection member lookup. With the full
stdlib preloaded, the table holds thousands of symbols.

The ids now come from `symTableStdCollectionsHostTypeId`, a per-symbol-table
memo filled incrementally. A one-element cursor records how many symbols have
already been folded in, and each newly appended `Std.CollectionsHost` symbol
overwrites its name's entry. The answers match the old lookup exactly: the
most recently registered symbol still wins, and a symbol registered after the
first query is still seen. The separate `stdCollectionsListTypeId` helper is
gone. Its three `is it the stdlib List` callers now use
`isStdCollectionsHostType(tbl, id, "List")`, and `.toList()`, which needs the
id itself, reads the memo directly.

Measured with the same CLI build, swapping only `Lyric.Lyric.TypeChecker.dll`
between runs and interleaving five rounds, on a generated 6,400-line file of
400 functions that each iterate and index `List`/`Map` values:

| | before (mean) | after (mean) |
|---|---|---|
| `lyric check` | 4.19 s | 3.92 s |
| `lyric build` | 4.43 s | 4.03 s |
| `lyric build --manifest lyric-web/lyric.toml` | 3.88 s | 3.51 s |

`lyric test lyric-compiler/lyric/typechecker_self_test.l` showed no measurable
change (16.0 s before and 16.5 s after, within run-to-run noise). Its time
goes to running 680 small checks.

The new `typechecker_self_test.l` cases put a user type of the same name and
the stdlib type in the same symbol table. The user type shadows the bare name
and the stdlib type is spelled qualified, so a memo that mixed the two up
would classify both the same way. The cases cover a `MapValueCollection`
iterated (only the stdlib loop binds the value type) and indexed (only the
user record is `T0143`), and a `Map` indexed (the stdlib `Map` types its
value, the user record is `T0143`). The fake `Std.CollectionsHost` harness now
also declares `MapValueCollection`.
