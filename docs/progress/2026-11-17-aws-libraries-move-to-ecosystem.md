# lyric-lambda, lyric-aws-secrets and lyric-aws-xray move to lyric-ecosystem (D620)

The three AWS libraries are removed from `lyric-lang` and now live in
`nichobbs/lyric-ecosystem` as `Lyric.Lambda`, `Lyric.AwsSecrets` and
`Lyric.AwsXRay` (docs/71 phase 4, D552, D561).

- Removed `lyric-lambda/`, `lyric-aws-secrets/` and `lyric-aws-xray/`.
- `ci.yml`: dropped the `lambda`, `aws-secrets` and `aws-xray` matrix entries
  and test steps, and the lyric-lambda and lyric-aws-secrets JVM suites (the
  workflow is about 8 KB smaller). `detect-code-changes.sh` `ECO_DEPS` matches.
  `publish.yml` no longer publishes `lyric-lambda`.
- `ecosystem-library-builds.sh` and `jvm-ecosystem-suites.sh` no longer build or
  test them; comments in the Maven helper scripts no longer cite them.
- README, CLAUDE.md, the book (chapters 21, 27, 29, appendix B) and docs 05, 25,
  35, 36, 39, 57, 59, 71 point at the new home. `Std.AnnotationMeta` and the
  `config { }` annotations stay in the standard library.
- `audit-axioms.sh`, `audit-kernel-stubs.sh` and `check-eco-deps-sync.sh` pass
  unchanged in meaning.
