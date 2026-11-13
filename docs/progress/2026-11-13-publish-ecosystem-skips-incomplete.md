# 2026-11-13 - Publish: the ecosystem job skips `incomplete` packages instead of failing on F0052

Publish run 1835 shipped every binary, the NuGet tool, checksums and `finalize-release`, but `publish-ecosystem` exited 1: `lyric-otel`, `lyric-db`, `lyric-mq`, `lyric-jobs` and `lyric-storage` are `stability = "incomplete"` (D552), so `lyric publish` refuses them with `F0052`, and the workflow counted each refusal as a failed library.

The refusal is the intended behaviour, so the job now detects `stability = "incomplete"` in a library's manifest before building it, records it as skipped (a `::notice::` plus a "Skipped (stability = incomplete)" section and count in the job summary) and carries on. Nothing about `F0052` changed: an incomplete package is still never published, and a direct `lyric publish` still fails. Real build or publish failures in any other library still fail the job. Dependants of a skipped library still resolve it from the workspace build output, as before.

Open question for the owner, not changed here: `lyric-testing` is published and has workspace dependencies on `Lyric.Mq`, `Lyric.Storage`, `Lyric.Db` and `Lyric.Jobs`, which are no longer published, so a registry consumer of `Lyric.Testing` may not be able to restore them. A library leaves the skipped set when the work that lands its backend changes its `stability`.
