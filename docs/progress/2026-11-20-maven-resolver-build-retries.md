# Maven resolver build survives transient Maven Central failures

`make maven-resolver` (`mvn package` over `resolver/pom.xml`) builds `resolver/target/lyric-resolver.jar` in several required CI jobs. On 2026-11-19 and 2026-11-20 it failed on heads of #9253, #9251, #9270 and #9267 with `Could not find artifact org.apache.maven.plugins:maven-resources-plugin:jar:3.3.1 in central` and `429 Too Many Requests`, unrelated to the change under test. #9243 had pinned the default-lifecycle plugin versions, which fixed a missing-version problem but not transient downloads.

## What changed

- `resolver/.mvn/maven.config` sets per-request HTTP retries for every `mvn` run on `resolver/pom.xml` (Maven 3.9's resolver properties `aether.connector.http.retryHandler.*` and the Wagon equivalents for older apt-installed Maven on self-hosted runners). `serviceUnavailable=429,503` makes the Apache transport retry 429 as well as 503, with a growing interval (5 s up to 60 s). Checked against a local server that always answers 429: Maven made 6 requests (1 + 5 retries) with 5, 10, 15, 20 and 25 s gaps.
- `scripts/ci/build-maven-resolver.sh` is the one outer retry (4 attempts, 15, 45 and 90 s backoff). Retries pass `-U` so Maven re-attempts artifacts cached as "not found" instead of failing on the cached result. `-q` is unchanged, so errors still print; the final failure exits non-zero. `make maven-resolver` calls it, so no workflow duplicates retry logic.
- `actions/setup-java` gets `cache: maven` with `cache-dependency-path: resolver/pom.xml` in the jobs that build the resolver (`ci.yml`, `publish.yml`, `windows-build.yml`, and the `lyric-test-setup` composite action), so a warm `~/.m2/repository` is restored and Central is rarely contacted. On self-hosted runners `~/.m2` is already persistent and the existing `flock` still serializes builds; the cache action only adds a restore.

The jar contents and `lyric restore`'s use of it are unchanged.
