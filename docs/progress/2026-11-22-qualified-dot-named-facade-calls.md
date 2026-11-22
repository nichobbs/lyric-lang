# Checker: `Alias.Type.f(x)` through an alias and a `pub use` chain (D741)

`L.Config.describe(c)` with `import Pu as L` and `Pu` re-exporting the declaring package is typed and recorded. Self-test: `llvm_project_self_test.l` (native).
