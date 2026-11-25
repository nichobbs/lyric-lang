# D506 - Record equality on TIR: array leaves element by element, Float leaves with the NaN rule

**Status:** accepted, implemented in the TIR builder (docs/70 phase 3c, §7.2; follows D164)

## Decision

1. **`a == b` and `a != b` on a structural record expand every leaf the checker's `RecordEqSite` lists**, including the two it used to leave as a single `IoEq`/`IoNeq` on the record. A `Float`/`Double` leaf (`floatLeaves`) is `{ val a = x; val b = y; a == b or (a != a and b != b) }` (D172: a value equals itself, `NaN` included). An array leaf (`arrayLeaves`, D167) is `{ val l = x; val r = y; var i = 0; var ok = true; while ok and i < len { if not (l[i] == r[i]) { ok = false }; i = i + 1 }; ok }` with the element compared by its `ArrayEqElem`: plainly, through a distinct type's `value`, with the NaN rule, as a structural record (the same record expansion), or as a nested array. These are the forms `arrayEqBlock` and `floatEqExpr` give on the AST.
2. **No new TIR node**: locals, `TsWhile`, `XIndex`/`IkArray`, `XAssign` and the `IoEq`/`IoLt`/`IoNot` intrinsics. The element read keeps the backend's bounds check (the AST form skips it with `__lyric_unchecked`); the index is always in range, so the check never fires.
3. **Still one `IoEq`/`IoNeq`** (never an I0002; `lyric prove` builds TIR): a record with a tuple or union leaf holding an array (`wrapLeaves`), an array element of that kind (`AEShape`), and a leaf path through a generic record. Their own step needs typed patterns over the leaf's cases.
