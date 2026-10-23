# D216 - Native dependency packages are lowered by reachability

**Status:** accepted, implemented (docs/67, #8429; builds on D203 and the reachability of the bundled standard library)

## Context

`compileProjectToNativeWithShape` lowered every package of the project in full and rooted reachability at every
package's functions. The packages of a path or workspace dependency (`NativeSourcePackage.features` is `Some`) were
treated as the project's own, so an `extern func` a dependency declared and nothing called still named its
`@library`, and its callers were emitted. Any native program that depended on `Lyric.Ui` linked `-lwebview` and
needed `libwebview` installed to build, although only the desktop host calls it.

## Decision

1. **A dependency package is lowered like a stdlib package.** Reachability is rooted at the project's own packages
   (`features` is `None`) only; a dependency's functions and externs are lowered when reachable, so an unreached
   extern never reaches `addExternLibrary`. The project's own packages stay fully lowered. A wasm32 `module` or
   `component` build exports the `pub` functions of every package it links, so it lowers dependencies in full. A
   dependency's `func main` is no longer a candidate entry point.
2. **Code that is not a plain function follows reachability too.** `PruneIndex` (`llvm_bridge.l`) models a record's
   methods and a protected type's members as one group per type. The call-key walk is syntax-only and does not know
   a receiver's type, so a group is live when any call key ends in the name of one of its methods, which is
   over-inclusive across types that share a method name and never under-inclusive. This is not the receiver-aware
   keying #8413 asks for; it is sound without it, and #8413 would only make the walk tighter. A protected type is
   also live when a call constructs it. A protected type that is not live is still registered (a signature or field
   may name it) but its lock/unlock wrappers are skipped (`CodegenUnit.deadProtecteds`). A non-generic `impl` is
   lowered when reachable code constructs its record, as for the stdlib; a generic `impl` stays registered.
   A dependency declaration is only a candidate for a caller that can import its package: the walk's bare
   `name/arity` fallback (the first declaration of a name in any package) no longer reaches a dependency package
   outside the caller's import closure. Without that, a call to any `run(a, b)` made `Ui.Host.Desktop.run`, and
   with it the webview externs, reachable from the native host. A function named as a value (`val cb = onEvent`) is
   found through the same scoped name match.
3. **Code that runs without a function around it is found lazily.** A module `val` initializer (hoisted into a
   function by `hoistModuleValInits`) runs when the `val` is read: `collectCallKeys` now records a `v:<name>` key
   for every path and member name it sees, and a dependency `val` of that name makes its initializer live. A field
   default and an invariant become live when the record or protected type is constructed or touched, and the
   bodies of generic members and of methods with type parameters of their own wait with the type. A default
   argument's call is found from the function that declares it, and a call that leaves out defaulted arguments
   reaches the declaration through the shorter arities `registerFileFns` now registers.
4. **Tests.** `native_dependency_self_test.l` builds a path-dependency project whose dependency declares an extern
   in a library that does not exist, for each shape above (plain function, record method including a call through a
   field chain, protected type, interface `impl`, module `val`, generic record method and default argument). A
   build that succeeds proves nothing reachable named the library; each is paired with a control whose program does
   reach the extern and must fail to link. `scripts/ci/ui-native-e2e.sh` no longer installs `libwebview` and checks
   that the native `lyric-ui` host binary has no `webview` dependency.

## Consequences

A native program on `Lyric.Ui` builds and runs without `libwebview`; only a program that opens a desktop window
links it. Dependency dead code no longer costs compile time or binary size. The group granularity means a record
or protected type with one used method lowers all its methods, so an extern behind an unused method of a used type
is still linked; a receiver-aware walk (#8413) would close that.
