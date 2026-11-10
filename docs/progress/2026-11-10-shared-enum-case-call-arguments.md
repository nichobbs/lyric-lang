# A shared enum case name passed as an argument is checked against its parameter (2026-11-10)

A case name several enums share (`Lib.On` for `Beam.On` and `Ray.On`) was an unresolved `TyError`, a
wildcard everywhere, so `takeInt(Lib.On)` or a call through a function value with an `Int` parameter was
accepted (#8872; the annotation, return and tail positions were fixed in #8871). The read is now a `TyError`
whose `DiagId` names the enums that own the case (`SymbolTable.sharedCaseOwners`, `sharedCaseIndexBase`),
and the central compatibility check `argSatisfiesParam` answers for it: it fits the parameter of an enum
that owns the case, and not a primitive's, a tuple's, a function's, an array's, a slice's or another data
type's; any other parameter (an interface, a type parameter) decides nothing, as before. Calls and
annotations, overload candidate filtering included, go through that one check; the earlier
annotation-only hook now reads the owners from the marker. Covered by `typechecker_self_test.l`.

Overload selection by type between same-arity declarations of one name does not arise in the language: a
package may overload a name only when one of the declarations is generic, and a bare name reaching the file
from two imported packages is T0123 whatever the argument types. A shared case therefore never has two
non-generic same-arity candidates to choose between.
