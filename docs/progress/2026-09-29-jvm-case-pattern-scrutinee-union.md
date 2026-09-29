# JVM resolves a bare case pattern in the scrutinee's own union first (#7761)

Suppose a package declares its own `union Option { case Some(value: T) case
None }` and then matches `case Some(v)` against a genuine `Std.Core.Option`,
such as `"abc".indexOf("b")` with `import Std.String`. The type checker
resolves the bare case name in the scrutinee's union and accepts the match,
and `--target dotnet` prints `some 1`. `--target jvm` threw
`Jvm.Codegen: match not exhaustive` at runtime.

The cause: the JVM erases a generic scrutinee (`Option[Int]`,
`Result[T, E]`) to `Object`. `resolveCaseClassJvm` and
`resolveBareCaseClassJvm` then had no scrutinee class to derive the case
from, so they fell back to `ctorClassFor`, which prefers the enclosing
package's same-named case. The stdlib value was tested with `instanceof`
against the local `Some` class, and no arm matched.

The fix applies the rule the checker and MSIL already use: resolve the case
name in the scrutinee's own union first, and fall back to the enclosing
package's unions only when the scrutinee type is unknown.

- The type checker records the union each case pattern matched
  (`recordCasePatternUnion`, called from `bindPatternTyped` for a
  constructor pattern and for a bare nullary-case name). It records into
  `SymbolTable.memberRecvClasses`, keyed by the pattern's span. That is the
  channel the JVM already reads the checker's nominal classes from (#7378).
  The alternatives of an or-pattern after the first are now walked too, in a
  scope of their own with their diagnostics discarded, so their case patterns
  are recorded.
- `Jvm.Codegen.casePatternScrutTyJvm` looks the pattern's span up and passes
  the recorded union to the case resolvers in place of the erased scrutinee
  type. This applies to the test and the bind of a constructor pattern and to
  the test of a bare nullary case. A name the checker recorded is treated as
  a case on the bind side, even when no constructor of that name is in scope.
  Nested patterns (`Ok(Some(v))`) resolve at each level.

Verified by the new dual-target `local_union_case_shadow_self_test.l` (6
cases), wired into `scripts/ci/compiler-self-tests-batch.sh` and
`scripts/ci/jvm-generics-self-tests-batch.sh`. A package declaring its own
`union Option` and `union Result` matches stdlib-returned values
(`String.indexOf`, `Std.Parse.parseOptInt`, `Std.Parse.tryParseInt`) with bare
`Some`/`None`/`Ok`/`Err`. Companion cases match the local unions' own values
and mix both in one function. Before the fix, dotnet passed all 6 and the JVM
failed the 4 cases that match stdlib values.
