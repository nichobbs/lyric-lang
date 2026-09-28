# Qualified value reads through a sub-package of the root no longer report T0020 (#7614)

Since #7583 registers every project package for each package's type check,
a project whose root package has symbols of its own rejected an imported
qualified VALUE read through one of its sub-packages:

```
error[T0020] unknown name 'App.Lib' (package App is not imported; add `import App`)
```

for `App.Lib.limit` in a file that imports `App.Lib`. Qualified calls
(`App.Lib.twice(...)`) were unaffected. The member-access walk
(`checkQualifiedMemberRef`) also visits the inner node `App.Lib` and asked
`checkQualifiedPackageRef` about member `Lib` of package `App`; with `App`
now loaded and not imported, it reported T0020 against the root package.
Found building nichobbs/cloud-agents against `main`
(`CloudAgents.GraphIngestOutbox.defaultMaxAttempts`, root package
`CloudAgents`).

`checkQualifiedPackageRef` now returns early when `pkg.member` is itself a
loaded package and `pkg` declares no symbol named `member`: the path
continues into that sub-package, and the enclosing node checks the real
package. A genuine member of the parent package is still checked, and a
genuinely unreachable sub-package is still reported against that
sub-package. cloud-agents also hit it through `CloudAgents.Db.sqlLiteral`,
where `CloudAgents.Db` is reachable through the file's imports; that now
builds too.

Verified by a new case in `scripts/ci/project-package-import-reachability-e2e.sh`
(run from `compiler-self-tests-batch.sh`) on both `--target dotnet` and
`--target jvm`: the imported form builds and runs (it reported T0020 before
the fix), and the unimported form still reports T0020 naming `App.Lib`.
