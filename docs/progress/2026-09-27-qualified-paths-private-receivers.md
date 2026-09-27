# 2026-09-27 — Qualified paths need a reachable import; private type receivers are T0097

D-progress-1011, #7495, #7499.

A package-qualified call into a package the file never imports
(`Std.Rest.RestClient.create(url)` or `Std.Rest.ping()` with no
`import Std.Rest`) used to type-check silently; whether it then built depended on the
backend (MSIL ran it because the stdlib bundle contains `Std.Rest`, JVM
codegen failed with `J008`), since the pipeline loads every stdlib
package's signatures whatever the file imports. It
is now **T0020** (`unknown name 'Std.Rest.RestClient' (package Std.Rest
is not imported; add import Std.Rest)`), with the same transitive
reachability test and `Std.Core` prelude exemption as the bare-receiver
check from D-progress-1001.

A package-private type used as a `Type.method(...)` receiver from another
package (`Widget.create(...)` or `Lib.Widget.create(...)` where `Widget`
has no `pub`/`internal`) is now **T0097**, whether or not the declaring
package is imported (it previously type-checked and ran). A `pub`
type-associated function on a
package-private type is not itself diagnosed; see D-progress-1011.

The imported multi-segment form (`import Std.Rest` +
`Std.Rest.RestClient.create(url)`) now builds on JVM as well: the alias
rewriter collapses a callee receiver whose qualifier prefix is an import
key, as it already did for single-segment packages.

Docs: docs/01 §3.1 and §9.2, book chapter 6, appendix B (T0020, T0097).
Tests: `typechecker_self_test.l` (unimported / imported / transitively
reachable / prelude qualified references, a local shadowing a package
root, private receivers bare, qualified, alias-rewritten, and in the same
package); `alias_rewriter_self_test.l` (the receiver collapse, and no
collapse without the import).
