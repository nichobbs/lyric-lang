# The JVM stdlib List's host name carries its arity (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`rows.add([1, 2, 3])` on a `List[List[Int]]` (`labelled_loops_self_test`, 238) was counted as "an argument conversion from slice[Int] to extern java.util.ArrayList`1[Int]". The checker types a bracket literal passed as a list's element as a slice, and the builder retypes such a literal to the `List[T]` the parameter wants (`retypeListLiteral`), but only for the host names `java.util.List` and `java.util.ArrayList`. The JVM stdlib's `List` resolves to the host class under its generic arity name, `java.util.ArrayList`1`, which the check did not recognise, so the retype never applied on the JVM.

## Decision

`isListHostName` also accepts `java.util.ArrayList`1` and `java.util.List`1`. The dotnet name was already `System.Collections.Generic.List`1`.

## Consequences

`labelled_loops_self_test` builds all 22 bodies on the JVM. Test: `tir_build_self_test.l`.
