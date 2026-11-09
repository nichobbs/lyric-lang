# Ecosystem remediation, phase 0 (D552, docs/71)

- Audited every non-compiler library; wrote `docs/71-ecosystem-remediation-plan.md`
  and recorded D552 (interface, reference backend and conformance suite per
  library; SDK backends move to a separate repository after phase 1;
  `stability` manifest field; JVM parity not a v1.0 gate).
- Chapter 29 matrix reconciled with the READMEs: proto and logging JVM cells
  corrected, search cell updated, rows added for mcp, docker, lambda,
  aws-secrets and aws-xray.
- `lyric-logging` README no longer calls the weaver and config blocks planned.
- `docs/12-todo-plan.md` item 3 now points at docs/71.
- Phase 1 started in two nested sessions (JVM backend fixes; protected-type
  interface dispatch and lyric-cache).
