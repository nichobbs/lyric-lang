# Expected-type inference batch: constructions and literals take their type from their position

A construction that fixes only part of its own type (`None`, `Ok(1)`, `newMap()`,
a bracket literal) is built at the type its position gives it, on every target.
Covered by `lyric-compiler/lyric/expected_type_inference_self_test.l` (18 cases on
dotnet, JVM and native, ilverify-clean on dotnet) and two new cases in
`typechecker_self_test.l`.

- **Calls through a function value (#8346).** Each argument of `f(None)` /
  `g(Ok(..))` is lowered against the function type's parameter, as a call by
  name is (`lowerCallArgForParamMsil`).
- **Generic methods (#8303).** A bare `None` argument of a method of a generic
  receiver takes the receiver's instantiated parameter type.
- **Nested collections (#8274, #7293, #8092).** `m.add(k, newMap())` builds the
  value at `V`; `newList[Int]()` / `newMap[K, V]()` (parsed as an index) is
  rewritten by `Lyric.Mono` to a binding annotated with the written type; a
  tuple that leaves a component open is recorded by the checker
  (`hoistOperandTypeSites`) so a `List` of tuples (element type erased on
  dotnet) holds a correctly typed `None`; `add(index, item)` on an
  element-erased receiver tests list-versus-map at run time.
- **Comparisons and branches (#8144, #7516, #8136, #7906).** The operand of `==`
  / `!=` and the branches of a consumed `if`/`match` that build a generic value
  with an open argument are recorded at the joined type, so `r == Ok(2i64)`
  compares one runtime type and `(Ok(1), 5)` beside `(Err("e"), 6)` joins.
- **Bracket literals (#8277, #8293, #7878, #7908).** Arguments for `slice[Long]`,
  `slice[List[Int]]` and tuple parameters take their shape from the parameter;
  the expected result binds a generic parameter nothing else binds; nested
  `List[List[T]]` is shaped; a lambda ending in a literal where a `List` is
  expected is recorded at that shape; a literal receiver of `.toList()` is the
  slice it converts on dotnet and the JVM.
- **Native `isNone(None)` (#8352).** A case construction whose type parameter
  nothing binds is instantiated at `Unit`.
- **Docs (#7881, #7707).** docs/01 §1.4 states that an integer literal never
  becomes a `Double`/`Float`; §2.7 describes the position rules above and
  return-position typing; the book's data-structures chapter and quick reference
  cover bracket-literal typing.

Already fixed on main and pinned by the new test file: #7906, #8136, #8278.
