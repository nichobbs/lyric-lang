# `[package] stability` and the `lyric publish` refusal of incomplete packages (D552 item 4)

`Lyric.Manifest` parses `[package] stability = "stable" | "experimental" | "incomplete"` into
`PackageSection.stability: Option[Stability]`; any other value is `F0051`. `lyric publish`
refuses an `incomplete` package with `F0052` before packing, a DLL lookup or any network
access. Covered by `manifest_self_test.l` (parsing and rejection) and
`scripts/ci/publish-stability-e2e.sh` (wired into `compiler-self-tests-batch.sh`).

Every ecosystem library's `lyric.toml` now sets the field (stable: auth, cache, feature-flags,
generator-sdk, health, i18n, logging, mail, proto, session, testing, validation, ws;
experimental: aws-xray, docker, forms, grpc, mcp, resilience, search, ui, web; incomplete:
aws-secrets, db, jobs, lambda, mq, otel, storage), each README carries a matching
`**Stability:**` line, and `scripts/ci/check-library-stability.sh` (run in the CI lint job)
fails when the two disagree. The chapter 29 matrix gained a Stability column. Graphics,
window, GPU, text, draw, game, access and unicode libraries are out of scope (D548).
Later status changes belong to the work that lands the backend.
