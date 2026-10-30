# CI, test and docs hygiene batch (#8537, #7141, #8472, #7542, #7533, #7770)

- **Unique decision ids (#8537, #7141).** `scripts/ci/check-decision-ids.sh`
  fails when two files in `docs/decisions/` share an id (`D<n>`,
  `D-progress-<n>`, `D-<word>-<n>`). It runs in the `actionlint` job with its
  own self-test (`check-decision-ids-self-test.sh`). Ids that were already
  duplicated are listed in `scripts/ci/decision-id-allowlist.txt` with the most
  files each may keep; the list can only shrink. The seven duplicated `D<n>`
  ids (D175, D204, D205, D207, D209, D230, D231) were renumbered to D267-D274
  and every reference in `docs/`, `book/`, `CLAUDE.md`, comments and scripts
  was moved to the id its entry meant. Four D230 references in `lyric-rt` and
  `lyric.full.toml` described trusted plugins and now name D231. The 22
  `D-progress-NNNN` collisions of #7141 stay allow-listed: a `D-progress` id is
  quoted by name from many progress entries and archive notes that do not say
  which of the colliding entries they mean, so renumbering needs a per-entry
  reading that #7141 did not ask for.
- **`examples/agent` (#8472).** `contracts.l`, `di-and-async.l`, `tests.l` and
  `config-and-aspects.l` are self-contained programs in current syntax.
  `scripts/ci/test-multi-package-examples.sh` runs the first, second and fourth
  on dotnet and the JVM and compares their output, and runs `tests.l` under
  `lyric test` on both targets.
  `r.mapErr { ... }` on a `Result` (there is no trailing-lambda call syntax, so
  it is the bare member `r.mapErr` followed by a block) is now T0113 at compile
  time instead of an "unsupported method" failure at run time;
  `scripts/ci/monad-unknown-member-negative-test.sh` pins it (docs/01 §
  accessors, book appendix B).
- **`@cfg` test items (#7542).** Tests in `lyric-mail`, `lyric-storage`,
  `lyric-search`, `lyric-jobs` and `lyric-aws-secrets` carry the `@cfg` of the
  feature they need instead of calling a per-feature helper that returns a
  sentinel. The two lambda suites that were left out of `[project.tests]` are
  registered with a file-level `@cfg`; CI runs `--features web` as well.
  `session_redis_jvm_tests.l`'s header no longer claims the runner skips
  file-level `@cfg` erasure.
- **Contract type arguments (#7533).** The v0.7.11 seed infers `isNone`'s type
  argument inside a contract (#7466), so `std/char.l` and `std/string.l` use
  `isNone(result)`; `string.l`'s `noChar` helper is gone. The stdlib bundle
  builds on the seed.
- **For-loop disposal (#7770).** `for_loop_dispose_enumerable_self_test.l`
  covers `Set[T]` and the key/value views on both targets, and joins the
  ilverify list.
