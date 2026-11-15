# Native backend on TIR: lists and slices (docs/70 phase 4a, D520)

`slice[T]` and `List[T]` over scalars and reference elements lower from TIR with the AST path's
`LyricList` kernel calls: literals, `newList`, `add`/`removeAt`/`clear`, `count`/`length`,
`toArray`/`slice`/`concat`/`append`, indexing, element assignment and `for`. The code generator
registers the list type on demand (`needLists`), as for tuples and closures.
`native-via-tir/lists.l` runs both ways and under AddressSanitizer. By-value element types, arrays,
`Map`/`Set` and element equality (`contains`, `indexOf`) stay on the AST path.
