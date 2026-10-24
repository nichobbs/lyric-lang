# Type checker: rigid type parameters in more places, T0208 and T0209 (#8332, #8449, #8018, #7786, #7978, #8104)

Worked the `group:typechecker-diagnostics` issues. Decisions in D231.

- A bare type parameter is rejected where a `Bool` is required: `while`, contract clauses, quantifier guards and bodies
  (T0132) and the operands of `and`/`or`/`not` (T0034) (#8332).
- A field declared as the record's own type parameter, read at the enclosing generic's type parameter, now has that type
  parameter as its type, so `bump(b.v)` against `inout Int` and `val n: Int = b.v` are type errors instead of ill-typed
  IL (#8449, #8018). One older self-test case that asserted the leniency was rewritten.
- T0208: `Box[Long](value = 5)` (explicit type arguments on a record constructor) is a diagnostic naming the annotated
  binding, instead of a code-generation failure (#7786). docs/01 no longer promises the form.
- T0209: two members of one protected type with the same name are rejected; MSIL could not lower them (#8104).
- `remove` on the stdlib `List`/`Map`/`Set` is typed `Bool` (#7978). Three `Unit` bodies that ended in a `remove`
  (`Std.HttpServer` kernel twice, `lyric-mq`, `lyric-testing`) now discard it with `val _ =`.
- MSIL: `x == y` on two values of a generic record's `T` boxed only the right operand (invalid IL, with or without a
  field read); the left one is now boxed too (`generic_closure_self_test.l`, dotnet and JVM).
- Audit: the compiler (stage 2 with the new checker), the full stdlib bundle, every ecosystem library and example, and
  the stdlib and library test modules were compiled with the new compiler; the hits above were the only ones.

Already fixed on `main` and closed: #7683 (argument types, #7969; arity, #7978; `List[Byte].add(Int)` is T0043), the
module-`val` half of #7777, the `Int`-to-`Long` and `Int`-to-`Double` parts of #7786, #7804 items 1 and 3, and #8104
item 1. Left open with a plan on each issue: #7809, #7204, #7804 item 2 (need host metadata in the target-specific
bridges), #7777 (JVM J008), #8257, #8100, #8018 (call-style member on a bounded `T`), #8047 (T0154 is the intended
outcome and is now tested).
