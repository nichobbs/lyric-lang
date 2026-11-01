# Bare enum case T0222 on every backend; union case named `Unit` on the JVM (#8667, #8652)

Two follow-ups in one change.

**T0222 (D312, #8667).** A bare enum case that two or more enums declare, with
none of them in the current package, an imported package or the expected type,
fell back to the first registered enum on MSIL, the JVM and native, and so could
read another enum's ordinal. The survey recorded in #8667 found the MSIL fallback
unreached in all 102 projects and 73 cloud-agents entries, so it is now a build
error on all three backends, documented in `docs/01` §9.2 and the book's
quick-reference. MSIL reports a positioned diagnostic; the JVM and native raise
the same text through their bridge boundaries. Native also stops preferring the
first registered enum for a bare case in an ambiguous bundle: the referencing
package's own and imported enums win, as on MSIL and the JVM.

**Union case named `Unit` on the JVM (#8652 item 4).** `case Unit` registers the
bare constructor key `Unit`; `recordRetClassOfBundleTe` resolved a bare `TRef`
return type through that registry before the reserved type keywords, so
`func f(): Unit` was recorded as returning the case class and each call
`checkcast` a void result (`J008 Jvm.Lowering: stackmap simulation underflow at
main`). Reserved type keywords now win. Native has no such lookup: it maps `Unit`
by name in its type lowering, so no change was needed there.

Tests: `union_case_named_unit_self_test.l` (dotnet and JVM),
`msil_bare_enum_case_guard_self_test.l`, `enum_case_collision_self_test.l` (JVM
and native resolvers), `llvm_project_self_test.l` (native two-package case).
Items 1 (`array[N, T]`) and 2 (generics declared in another package) of #8652
remain open.
