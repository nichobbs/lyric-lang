# Cross-package generic re-checks and shared union case names (#8530, #8019, #8481)

See D285.

- **#8530.** A generic declared in another package and bounded by `Add`/`Sub`/`Mul`/`Div`/`Mod`/`Compare` can be
  specialised at a distinct or record type the caller declares on dotnet and JVM. The re-check runs in the declaring
  package's scope with the caller's type declarations added; M0008 is gone.
- **#8019.** Specialisations of another package's generic whose own body spells `UInt`/`ULong` are re-checked, so
  those operands lower unsigned when the type arguments are signed.
- **#8481.** `return Both(n = 2)` builds the case of the expected union when two unions of a package share the case
  name, on the JVM and native backends.
- Tests: `scripts/ci/crosspackage-bounded-ops-unsigned.sh` (restored dependency, dotnet and JVM),
  `lyric-compiler/lyric/union_shared_case_self_test.l` (dotnet, JVM, native).
