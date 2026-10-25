# 2026-10-25 - alias-qualified types resolve to the same registration as their constructors

A package's types can be registered more than once in one type check, for
example when the package is reached both as a restored dependency and from
source. Each registration has its own TypeId. A qualified constructor
(`B.Choice(...)`, via `symTableTryFindInPackage`) and the package's own
signatures resolve to the newest registration. The qualified type `B.Choice`
under `import Ui.Plugins.Build as B` alone, where `Choice` is not visible
bare, scanned the candidates oldest-first in `resolveTypePath`. So
`val cs: List[B.Choice]` followed by `cs.add(B.Choice(...))` failed with
T0043 "these are two different types named 'Choice'". A selective import
masked the bug, because the bare lookup then already picked the owner's
newest entry.

`resolveTypePath`'s owner-qualified override now scans newest-first, like
every other lookup. The type-checker self-test registers a package twice and
checks that an alias-qualified annotation, its constructor and a parameter of
the package agree. `lyric-ui/plugins/build/tests/build_tests.l` (D230) is back
to the `B.Choice` spelling.
