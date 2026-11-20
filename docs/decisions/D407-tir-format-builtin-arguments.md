# D407 - `format1` to `format4` take arguments of any type like `println` (docs/70 phase 3a, #8613)

**Status:** shipped; extends the polymorphic built-ins of D-progress-947.

## Context

`format1`-`format4` are codegen built-ins whose parameters the checker types with holes, so that `format1("a={0}", 42)` checks as `println(11)` does. The builder counted a call of one with a number or a `Bool` argument ("a built-in call with an argument the builder cannot check", I0002), because only `println`, `print`, `toString`, `hashCode` and `default` were known to take arguments of any type: `LlvmStdlibSelfTest`'s `T::main` programs.

## Decision

The four names join the polymorphic built-ins (`genericBuiltin`): their arguments are built as the checker typed them and passed as they are, as `println`'s are. The built-ins' lowering already formats an argument by its type.

## Results

`format_builtin_args` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` (verifier clean) and runs (exit 4).
