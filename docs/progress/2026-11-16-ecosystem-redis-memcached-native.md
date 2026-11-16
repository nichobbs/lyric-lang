# Ecosystem: the Redis and memcached backends run on native (2026-11-16)

`Lyric.Cache.Redis`, `Lyric.Session.Redis` and `Lyric.Cache.Memcached`
(nichobbs/lyric-ecosystem) claim `native` in `[package] targets`
(lyric-ecosystem#9). They sit on `Lyric.Redis` and `Lyric.Net`, which were
already on native, so the work was in this repository.

## What it took here

- `Std.Testing.assertPanics` on native (D608, #9141). It was implemented with
  `try`/`catch`, which native cannot compile, so every test file that used it
  was refused; this was the only thing these three packages lacked. The body
  now runs in a forked child and the parent reads the verdict from its exit.
- A cap on abandoned bounded name lookups (D605, #9137), found while reviewing
  that change.
- `Std.Tls.Certificate` carries every certificate of its PEM text on dotnet and
  the JVM as native already did (D610, #9146), which removed the last
  per-target difference from the S3 and SQS TLS tests.
- MSIL and JVM resolve names by scope (D609, #9130) and `lyric-testing`
  builds for the JVM again (#9135). Not needed for native, but found in the same
  pass over the cross-package name rules.

## Verified

On native in the ecosystem's CI: the hermetic suites, and the integration
suites against Redis (plain, TLS and mutual TLS) and memcached (plain, TLS and
authenticated). Linux x86-64 only.

## Differences on native

A panic in application code cannot be caught: it ends the process. The text of
a failed TLS handshake is OpenSSL's. A test's `assertPanics` body runs in a
forked child, so what it does to in-memory state is not visible afterwards;
Windows and wasm32-wasi have no fork (#9157).

## Not done

The other pure-Lyric backends (Azure Blob, GCS, ActiveMQ, RabbitMQ, Flipt) have
not been taken to native. `Lyric.Cache.*` aspect templates are not resolved in
native project builds (#3498). No backend has been run against its production
service in CI.
