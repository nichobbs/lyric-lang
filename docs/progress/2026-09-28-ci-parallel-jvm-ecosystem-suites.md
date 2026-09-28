# CI: JVM ecosystem suites run three at a time (#7612)

`scripts/ci/jvm-ecosystem-suites.sh` ran its seven `--target jvm` library
suites (storage, resilience, jsonrpc, mcp, health, generator-sdk, web) one
after another. On #7609's run that took 265 s, the longest step of
`compiler-self-tests-jvm-b`, which at 8.6 min had become the longest job in
CI.

The script now runs `LYRIC_JVM_SUITE_JOBS` suites at a time (default 3).
Each suite's output goes to its own log, and the logs are printed in suite
order at the end. Every suite still runs after a failure, and the script
fails if any did.

Running them together is safe. On `--target jvm`, `lyric test --manifest`
compiles a workspace dependency's source straight into the test bundle
(`cmdTestManifest` never builds the dependency's own `bin/` for JVM), so each
suite writes only under its own library's `.lyric-test/`. `web`'s Maven
resolver build is already serialized by `manifest-jvm-maven-test.sh`'s
`flock`.

Verified locally: all seven suites pass run three at a time (27 tests,
189 s wall).
