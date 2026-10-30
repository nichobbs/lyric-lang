# 2026-10-30 Lint and T0210 follow-ups

Follow-ups to the review of PR #8602.

- **T0210 wording.** The message now reads "package P declares no 'X', so it cannot be imported": the check never judged visibility, so "public" was wrong. docs/01 records the wording and the deliberate leniency (packages with an extern package, fixture, error item or destructuring `val` are never diagnosed).
- **Did-you-mean through re-exports.** `nearestDeclaredName` walks the same imported packages `packageDeclaresName` does; ties go to the first declared name. Covered in `typechecker_self_test.l`.
- **`lintPackage`** builds one L007 type registry per package key instead of one per file (was quadratic in the file count); behaviour is unchanged.
- **L002 on UFCS names.** `func ServeTlsError.message(...)` was reported as non-camelCase; L002 now checks only the last segment of a dotted name. Covered in `lint_self_test.l`; docs/01 L002 row updated.
- **T0197 on an `impl[T]` body.** A test pins that a type parameter of an `impl[T] ... for Box[T]` method body is not diagnosed (the `isSelfTypeArgument` suppression).
