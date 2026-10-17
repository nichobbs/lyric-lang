# Native: `.toNat()` and bare `None` branches (D-progress-1051)

`.toNat()` now lowers on `--target native` as the checked conversion `--target dotnet` has:
a negative value or NaN panics with `toNat: value must be non-negative` (#8366). An
unannotated `val` whose `if`/`match` branches mix `Some(...)` and a bare `None` now lowers
on native: the `None` branch takes its sibling's type (#8363), so `Std.Http`'s three
workaround annotations are gone. Tests in `llvm_stdlib_self_test.l`.
