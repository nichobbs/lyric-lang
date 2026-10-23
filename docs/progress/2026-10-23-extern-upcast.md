# Explicit extern upcast `externAsObject` and a type-checked JVM stdlib bundle (#7975, #7976)

Records D212.

- **`externAsObject(x)`** is the explicit upcast from an extern type to the
  host's root object type, for kernel and extern-boundary code. The type
  checker types it (`T0205` for a non-extern operand, `T0206` when no root
  object extern type is declared or on `--target native`), the mode checker
  confines it to files and functions annotated `@unsafe_ffi` (`N0103`), and
  `externAsObject` joins the reserved built-in names (`T0140`). MSIL boxes a
  value-typed operand and otherwise emits nothing; the JVM leaves the reference
  and retypes it `java/lang/Object`. No implicit widening, no upcast to a
  named extern type, no downcast.
- **`Jvm.Bridge` type-checks every bundled stdlib package** and a type error
  stops the build (`tcFatal`, warnings quiet), reachable or not, as
  `--target native` does since #7933. `_kernel_jvm/http_host.l` now builds its
  `List[JObject]` of reflection arguments through `externAsObject`.
  The gate also found three further ill-typed JVM kernels (`path_host.l`,
  `string_host.l`, `regex_host.l`: a `String` returned as `String?`, a two-argument
  `indexOf`, a `String` returned as a `CharSequence`), now typed through
  `String.valueOf` at the host boundary.
- Tests: `extern_upcast_self_test.l` (dotnet) and `extern_upcast_jvm_self_test.l`
  (JVM) run real upcasts end to end; `typechecker_self_test.l` and
  `modechecker_self_test.l` cover `T0205`, `T0206`, `T0140` and `N0103`;
  `scripts/ci/jvm-stdlib-type-check-gate.sh` (run from
  `jvm-generics-self-tests-batch.sh`) builds a program importing every public
  `Std.*` package and checks that an ill-typed kernel in a temporary stdlib
  copy fails the build.
- Docs: `docs/01` §11.4, `book` §13.9.1 and appendix B, `docs/decisions/D212-extern-upcast.md`.
