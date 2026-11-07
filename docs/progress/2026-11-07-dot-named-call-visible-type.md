# A `Type.f` call binds the function of the package whose `Type` is in scope (#8874, D336)

Two packages that each declare a type `Seed` with a dot-named `Seed.base()` made
a file importing only the second bind the first's function on both backends: the
checker's `typeQualifiedDotSig` answered with the first registration of the
dotted name, whatever the file imports. `dotSigOfVisibleType` now picks the
candidate whose package declares the one `Seed` in scope, and falls back to the
old lookup when the type is not a single visible declaration.
`emitter_project_self_test.l` has the two-package case on MSIL and JVM.
