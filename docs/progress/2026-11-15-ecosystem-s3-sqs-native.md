# Ecosystem: the S3 and SQS backends run on native (2026-11-15)

`Lyric.Storage.S3`, `Lyric.Mq.Sqs` and `Lyric.Aws.Credentials`
(nichobbs/lyric-ecosystem) claim `native` in `[package] targets`
(lyric-ecosystem#8). They are pure Lyric over `Std.Http`, so nothing was
ported: the work was in this repository, in what the native target was
missing.

## What it took here

- `String + x` for every scalar on native, which also unblocked `Std.Xml`
  (D606, #9089), and constructor names resolved by package scope (#9088).
- `Std.Http` on native runs a send within its cancellation token's limits
  (D605), so a timeout is a result there as on the other targets.
- The conformance suites as their own package, `lyric-conformance`, which
  depends only on the interface packages and builds for every target (D604).
- `lyric test --manifest --target native` (D607).
- Methods on field chains of another package's types, names read through a
  `pub use` facade alias, and defaults lowered in the declaring package
  (#9136).

## What the packages changed

No `try` is left in the S3 and SQS clients: the calls it wrapped return `Err`
on every target. The one `try` that guards a user-supplied credential provider
is a package in two files, the shape of D604: the managed targets catch a
panic, native calls the provider directly. `Lyric.Mq.Sqs` reads the characters
of a string in one package with a UTF-16 file and a UTF-8 file.

## Verified

On native, in the ecosystem's CI: the hermetic suites (which include each
interface's conformance suite against an in-process fake server), the
integration suites against MinIO and ElasticMQ, and all three packages against
AWS Emulator, which checks request signatures. Linux x86-64 only.

## Differences on native

A panic cannot be caught (D-N-003): a credential provider that panics, or a
violated `requires:`, ends the process. A PEM text with several certificates
trusts all of them on native and the first only on dotnet and the JVM (#9146).

## Not done

`Lyric.Cache.Redis`, `Lyric.Session.Redis` and `Lyric.Cache.Memcached` build
on native but their tests use `Std.Testing.assertPanics`, which is implemented
with `try` (#9141). The other pure-Lyric backends have not been taken to
native. Neither AWS backend has been run against AWS itself.
