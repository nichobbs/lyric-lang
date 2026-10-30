# JVM `==` on `List`/`Map`/`Set` follows D172 (#8439)

`==` and `!=` on a non-`String` reference on `--target jvm` called
`Objects.equals`, so `ArrayList.equals` compared a `Double` element with
`Double.equals`: `[0.0] == [-0.0]` was false, against D172 and dotnet.

- The operator now calls the package's `__lyricKeyEq` helper, which is emitted
  in every package that uses it.
- `__lyricKeyEq` gained `HashSet` and `HashMap` arms: equal sizes, then each
  member (key) of the left side must match one on the right, by the host lookup
  first and by a D172 scan when that misses. A map's values at matched keys are
  compared through the helper.
- Tests: `stdlib_parity_self_test.l` (`List[Double]`, `Set[Double]`,
  `Map[String, Double]` with `0.0`/`-0.0` and `NaN`), dotnet and JVM.

Not covered: native `==` on a `List`/`Map` compares by address (no structural
collection equality there), and the JVM hash helper does not yet fold a
`Set[Double]` field's zeros alike.
