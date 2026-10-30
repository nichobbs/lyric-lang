# Name-resolution fixes (D267)

Shipped: #7799 (qualified names through a facade's re-exports; MSIL/JVM
agreement on a transitively reachable host package), #8350 (a module-level
function-typed `val` hides an imported function in call position), #7368
(ambiguous-qualifier T0123 message), #8562 (explicit alias type argument).

- `typechecker_exprs.l`: `pkgReexportsFrom`, `packageReexportsMember`,
  `bareNameIsModuleValue`, `anyPackageEndsWithQualifier`; qualified expression
  paths require a directly imported package.
- `type_alias_resolve.l`: `resolveAliasIndexAt`.
- Tests: `typechecker_self_test.l`, `mono_self_test.l`,
  `name_resolution_self_test.l` (dotnet and JVM).

Not changed: #7217 and #7970 already behave as the issues require on `main`;
#7214 is skipped: docs/01 §3.1 deliberately leaves a `pub` signature naming a
package-private type legal and warns with lint L007, so turning it into a
compile error is a language decision with ecosystem fallout, tracked on the
issue.
