# 2026-11-03 Unpinned type arguments warn (docs/70 phase 3a, D335)

- New warning **W0034** where Mono defaults an imported generic's unpinned type argument to `Object` ("cannot infer type argument(s) ... write 'f[...](...)'"). It is step one of replacing the default with the error **T0224**; the call still specialises as before. `@externTarget` generics and position-less calls never warn.
- Census: 22 hits locally (10 in ecosystem `_kernel/net` externs, excluded; 12 in `core_tests.l` and `book_ch07_tests.l`, migrated to explicit type arguments). Stage 2 and the manifest and stdlib-test pass are clean afterwards; CI's logs cover the rest.
- Mono self-tests: an unpinned argument is W0034 once, a fully pinned call has none.
- Next: switch W0034 to T0224 and delete the `Object` fill once CI shows no hits.
