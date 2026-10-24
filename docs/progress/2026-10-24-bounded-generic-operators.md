# Operators on bounded type parameters (#7996, #8017)

`where T: Add` (and `Sub`, `Mul`, `Div`, `Mod`, `Compare`) now makes the matching
operator valid in the generic body, and the operator means the right thing at every type
the generic is specialised at (D224).

- **Checker.** `inferBinop` accepts an arithmetic or relational operator on a type
  parameter bounded by the operator's marker (the enclosing function's resolved `where`
  bounds now ride on the checker's `Scope`), requires both operands to be that one
  parameter (T0031 / T0033), and types the result as the parameter (`Bool` for a
  comparison). A compound assignment on a type parameter needs the bound too (T0030; it
  was accepted unchecked).
- **Lowering.** `Lyric.Mono` flags each specialisation that binds an operator-bounded
  parameter to a non-scalar type (`UnsignedSpecRequest.opBound`); `Lyric.Pipeline` re-checks
  it as the non-generic function it is, and lowers the distinct-type, distinct compound
  and record-arithmetic sites recorded on that body (`SpecArraySites.distinctOps`,
  `.distinctCompound`, `.recordArith`) with `lowerDistinctOps` / `lowerRecordArith`.
  Scalar primitives need no rewrite.
- **M0008.** A generic declared in another package cannot be lowered for a distinct or
  record type declared by the caller; that specialisation is a hard error.
- **Tests.** `typechecker_self_test.l` (each operator with and without its bound, the
  one-parameter rule, compound assignment, the docs `sum` example), `mono_self_test.l`
  (opBound flagging, re-check records the operator sites), and the runtime
  `bounded_generic_ops_self_test.l` on dotnet and JVM (Int, Long, Double, UInt, String,
  a distinct type, a range subtype, a homogeneous numeric record, evaluation order,
  `sum` with `T.default()`, compound assignment), registered in `ci.yml` and the
  Makefile.
- **Docs.** `docs/01` (generics, `where` clause) and the book's quick reference.
