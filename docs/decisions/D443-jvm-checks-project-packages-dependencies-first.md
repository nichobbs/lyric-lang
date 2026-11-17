# D443 - The JVM bridge checks project packages dependencies first (docs/70 phase 3a, #8613)

**Status:** shipped; completes D527.

## Context

A call that leaves out a defaulted argument another package declares takes the default that package's interface carries (D482). The interfaces live in one `DepDefaults` store per build, and a package registers its interface when it is checked under `--verify-ir`. On `--target jvm` a project's entry package was checked before the packages it imports: the build path ran the entry package's middle end before the bundle loop reached its siblings, and the check path put the entry package first and then the siblings in `jvmBundleClosure`'s reachability order, not a dependency order. The sibling's interface was not in the store when its caller was checked, so `g(7)` of `tir-foreign-defaults-e2e.sh` counted "a default argument declared in another package" (D527, "Not covered").

## Decision

- `jvmProjectDependencyOrder` orders the project packages' files so that each comes after the project packages it imports (a post-order walk of their imports).
- The project check path walks its packages in that order.
- The build path, when `LYRIC_VERIFY_IR` is set (`pipeVerifyIrEnabled`, new), first runs `pipeCheckFront` over each non-entry project package in that order against the shared store, so the entry package finds their interfaces. Their diagnostics go to a throwaway sink: the real pass reports them. Without `--verify-ir` nothing reads the store and nothing extra runs.
- `tir-foreign-defaults-e2e.sh` builds each case with `--target jvm` as well and requires the body of B to build and verify.

## Not covered

The native bridge has no restored packages and builds project packages one by one in its own order; it has the same question and is tracked with the native lowering.
