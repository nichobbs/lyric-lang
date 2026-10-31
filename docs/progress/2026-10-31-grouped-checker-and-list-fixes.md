# Grouped fixes: protected fields (#8672), shared nullary cases (#8649), List of tuples (#8668)

- **#8672 (D305, T0221).** A protected type's field named through a value of the
  type outside its own members is rejected, read and write, in the declaring
  package and in importers. Reject-corpus cases added; the stdlib, ecosystem
  libraries, examples and compiler sources contain no such access.
- **#8649.** A bare nullary case shared by two unions of one package resolves to
  the expected union: the checker resolves it against the expected type
  (`sharedBareCaseOfExpected`, including a call argument), the JVM codegen takes
  the case class from the expectation stack, and native builds it through
  `caseConstructForExpected`. `union_shared_case_self_test.l` covers return, tail,
  argument and typed binding on all three targets.
- **#8668.** On dotnet a `List` of tuples is the erased `List<object>`, so
  `indexOf`/`lastIndexOf` bound to `String.IndexOf` (an access violation) and
  `remove` to a pop-only fallback. The checker now records the stdlib `List`
  receiver (`stdlist|` key in `memberRecvClasses`) and `Msil.Codegen` lowers the
  three methods through `List.IndexOf`/`LastIndexOf`/`Remove`. Native had no list
  `lastIndexOf` or `remove(value)` at all; both are added over the existing
  structural-equality scan. `list_tuple_elem_methods_self_test.l` on all targets.
