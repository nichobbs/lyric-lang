# Origin-scope re-checks use the origin package's imports (docs/70 phase 2d, D336)

A specialisation of another package's generic is re-checked in its declaring
package's scope to recover the callees, arities and receiver classes the
consumer's check never saw. The re-check used the consumer's per-file header
table and turned selective imports into whole ones, so a bare call in the
generic could bind to a same-named export of the consumer's imports (T0123,
no callee recorded). It now uses the origin's own declared imports. The JVM
reads origin callee sites (`foreignCalleeSites`) before its bare-name keys.
See D336 item 7; `emitter_project_self_test.l` (`EPOs`, `EPOg`, both targets).
