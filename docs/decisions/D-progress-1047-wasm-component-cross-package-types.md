# D-progress-1047: Cross-package types in component signatures

**Status:** shipped (W4 follow-up, #8117 item 2)

## Decision

1. A component export or host import may name a `pub` (or `internal`) record, union or enum
   declared by another package of the same project, through any import form the language
   allows: a whole import (`Invoice`), an alias (`M.Invoice`), a renamed selector
   (`import Model.{Invoice as Inv}`), a trailing-segment qualifier (`Model.Invoice`) or the full
   package path. A non-`pub` type, or one from the standard library or a restored package, is not
   carried; the export is left out with a `W0040` note, and an import is `N0018`.
2. The shim generator now runs after every own package is parsed, so each package's shims can
   resolve the types its imports reach. A foreign type is resolved in its declaring package's own
   scope (its fields may name that package's other types), and its WIT type carries the
   package-qualified Lyric name. The generated Lyric spells it fully qualified, including union
   cases (`Proj.Model.Shape.Circle(...)`), so it type-checks whatever the importing file's import
   form is.
3. The exporting package's WIT interface declares its own copy of each type under the simple
   name. The declaring package gets no interface unless it exports functions of its own; the
   copies are structurally identical records and variants, so a host sees plain objects either way.
4. Two different types that would share a WIT name in one interface, or a function named like a
   type it uses, keep the function out of the component with a `W0040` note.
5. The native backend lowers a package-qualified member chain such as `Proj.Model.Currency.Usd`
   (a nullary case or enum case) written as nested member accesses; before, only a flat path
   reached the enum and union-case lookup, so the head was read as a local variable.

## Not covered

A type from a restored (NuGet or registry) Lyric package, and from the standard library
(for example `Std.Time` values); both stay outside the project's own packages.
