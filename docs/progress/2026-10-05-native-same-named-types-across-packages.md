# Native: same-named types across packages resolve in the right package (#8155, #7990)

- Native codegen resolved a bare type name to the first same-named type registered anywhere in
  the bundle. `examples/ui-customers` hit it three ways, all fixed in `llvm_codegen.l`:
  an imported `Route` union lost to lyric-web's `Route` record (`lookupHeapType` now prefers a
  type in a package the caller imports); a callee's declared parameter and return types were
  resolved in the caller's package (`sigTypeToN` / `sigRetTypeToN` resolve them in the
  signature's own package, so `Customers.List.Logic.update` takes its own `Model`); and a
  cross-package function value passed to a generic record constructor had no expected type
  when nothing else bound the record's type parameter (`fnRefLambdaWant` takes the closure
  type from the callee's signature).
- Test: `llvm_project_self_test.l` builds a bundle with a `Route` record and union, two
  `Model` records of different layouts and a generic `Prog[M]` built from each package's
  `update`, and asserts the exit code (ASan).
- Still open on #8155: `examples/ui-customers` now stops at `async` interface methods
  (`CustomerRepository.find`), which native does not yet dispatch through the vtable, and
  the `-lwebview` link and desktop smoke are untouched. #7990 and #8154 remain open.
