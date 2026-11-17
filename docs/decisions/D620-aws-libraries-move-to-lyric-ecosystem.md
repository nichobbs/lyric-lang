# D620 - lyric-lambda, lyric-aws-secrets and lyric-aws-xray move to lyric-ecosystem

**Status:** shipped. Applies D552 and D561 (docs/71 phase 4).

## Context

D552 split the ecosystem into target-neutral interfaces with a reference backend
and conformance suite in `lyric-lang`, and SDK-bound backends in a separate
repository, `nichobbs/lyric-ecosystem` (D561). The three AWS libraries bind to
the AWS SDKs for .NET and Java (`AWSSDK.SecretsManager`,
`AWSSDK.SimpleSystemsManagement`, `Amazon.XRay.Recorder.Core`,
`software.amazon.awssdk` and `aws-xray-recorder-sdk-core`) or to the Lambda
runtime API. They define no target-neutral interface other libraries implement,
so nothing in `lyric-lang` needs them, and their 41-artifact Maven restore was
the heaviest in CI.

## Decision

1. `lyric-lambda` (`Lyric.Lambda`), `lyric-aws-secrets` (`Lyric.AwsSecrets`) and
   `lyric-aws-xray` (`Lyric.AwsXRay`) are removed from `lyric-lang` and live in
   `lyric-ecosystem` as separately versioned packages that declare their
   supported targets in `[package] targets`.
2. Their CI moves with them: the `ecosystem-tests` matrix entries (`aws-xray`,
   `aws-secrets`, `lambda`) and the `ECO_DEPS` table in
   `scripts/ci/detect-code-changes.sh` (kept in sync by
   `scripts/check-eco-deps-sync.sh`), the JVM suites in `ci.yml` and
   `scripts/ci/jvm-ecosystem-suites.sh`, the library build tiers in
   `scripts/ci/ecosystem-library-builds.sh`, and the `lyric-lambda` entry in
   `publish.yml`'s tier 4.
3. The compiler and standard library keep what the libraries consume:
   `@secretsManager` / `@parameterStore` are ordinary config-field annotations
   read through `Std.AnnotationMeta` (D225) and `Std.ConfigOverride` (D230), and
   the aspect templates they use are compiler features. `docs/35-lambda-library.md`
   stays as the design document, with a status line pointing at the new home.
4. Historical decision-log and progress entries that name the old paths are left
   as written; they describe what shipped when.

## Consequences

- This change must merge after the `lyric-ecosystem` change that adds the three
  packages, so the libraries are never absent from both repositories.
- `lyric-health` keeps its pointer to docs/35 for the AOT-safe registration model.
- The `lyric-compiler` self-tests that mention these libraries in comments test
  compiler behaviour and are unchanged.
