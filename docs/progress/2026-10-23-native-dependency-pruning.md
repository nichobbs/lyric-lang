# Native dependency packages are lowered by reachability (#8429, D216)

- `compileProjectToNativeWithShape` roots reachability at the project's own packages and lowers the packages of
  path and workspace dependencies like the stdlib closure: an extern nothing reachable calls never names its
  `@library`, so a native app on `Lyric.Ui` no longer links `-lwebview`. The walk is split into `reachKey`
  (one call key) and `walkReachableFns`, with a `pending` queue for code that becomes live late.
- `PruneIndex`: record methods and protected types are member groups made live by a call key ending in a method
  name (or, for a protected type, a construction); dead protected types stay registered without their wrappers
  (`CodegenUnit.deadProtecteds`); non-generic `impl`s follow the record-constructed marker; module `val`
  initializers, field defaults and invariants are found lazily (`v:<name>` keys, construction); default arguments
  and shorter call arities are followed. `--shape module|component` keeps full lowering.
- Tests: ten cases in `native_dependency_self_test.l` (extern in a library that does not exist, with a
  control per case that must fail to link); `ui-native-e2e.sh` drops the `libwebview` install and asserts the
  host binary has no webview dependency.
- Left open: receiver-aware keying (#8413) would make the walk tighter than the method-name groups.
