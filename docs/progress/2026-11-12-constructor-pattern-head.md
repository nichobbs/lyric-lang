# 2026-11-12 - Checker: a constructor pattern whose head is no case of the scrutinee is T0129 (D584, #9024)

`case P(0, b)` against a record and `case Nope(k)` against a union used to check cleanly and then fail with `I0001` on the names they bind. The checker now reports T0129 for both (a record head also gets a hint to use `P { x = 0, y }`); a positional record pattern is not added, since the language reference defines none. `typechecker_self_test.l` adds three cases (1148 pass). docs/01 and the book's T0129 row are updated.
