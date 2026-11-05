# MSIL: a specialised generic's callee test and review leftovers (#8612)

D336.

- `emitter_project_self_test.l` covers a bare call inside a specialised copy of
  another package's generic when the consuming package imports a package that
  exports a same-named function (the callee is the declaring package's).
- `qualifyDefaultCalleesMsil` qualifies only a function declared directly in
  the package (`calleeIsOwnFunctionMsil`), not one in a sub-package; the stale
  `declScopeDefaultMsil` comment is corrected.
- The JVM does not bind that case correctly yet (#8792: bare-name keys, with the
  census and why re-checking in the origin's scope is not a safe site source).
