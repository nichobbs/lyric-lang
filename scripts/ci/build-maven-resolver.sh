#!/usr/bin/env bash
# Builds resolver/target/lyric-resolver.jar, retrying transient Maven Central
# failures (429s, missing-artifact flakes) a bounded number of times.
#
# Per-request HTTP retries live in resolver/.mvn/maven.config; this wrapper is
# the outer retry for failures that survive them. Retries pass -U so Maven
# re-attempts artifacts it cached as "not found" (*.lastUpdated) on the failed
# attempt instead of failing instantly on the cached result.
set -euo pipefail

cd "$(dirname "$0")/../.."

max_attempts="${LYRIC_MAVEN_ATTEMPTS:-4}"
backoffs=(15 45 90)

attempt=1
extra=()
while true; do
  if mvn package -q -DskipTests -f resolver/pom.xml ${extra[@]+"${extra[@]}"}; then
    exit 0
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "build-maven-resolver: mvn failed after $attempt attempt(s)" >&2
    exit 1
  fi
  delay="${backoffs[$((attempt - 1))]:-90}"
  echo "build-maven-resolver: attempt $attempt failed; retrying in ${delay}s (with -U)" >&2
  sleep "$delay"
  extra=(-U)
  attempt=$((attempt + 1))
done
