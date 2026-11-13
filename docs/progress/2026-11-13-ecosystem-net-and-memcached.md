# 2026-11-13 - lyric-ecosystem: one socket and TLS kernel (`Lyric.Net`), and memcached (docs/71 phase 4)

Follows `2026-11-13-ecosystem-tls-and-second-wave.md`. Merged in nichobbs/lyric-ecosystem#5.

**`Lyric.Net`.** `Lyric.Redis`, `Lyric.Mq.ActiveMq` and `Lyric.Mq.RabbitMq` each carried a copy of the same socket kernel, TLS option code and URL authority parsing. They now share one package: `Net.Tcp` (connect with timeout, a read that distinguishes data, timeout and end of stream, a write with a progress timeout; `TcpClient` + `SslStream` with a dedicated reader thread per connection on dotnet, `Socket` + `SSLSocket` on the JVM), `Net.Tls` (options, validation, the two-key insecure-verification rule), `Net.Url` and `Net.Tcp.Testing`. The clients keep their public APIs; about 5,000 lines of duplicated source and tests are gone. It exists because the stdlib has no TCP client on the JVM and no client TLS upgrade (#9042, #9064); a stdlib API would replace it.

The move fixed one defect: `Lyric.Redis` connected on the shared .NET thread pool, so `open` and every reconnect timed out under a busy pool. `Lyric.Redis` also gains an additive custom CA, and `Lyric.Mq.RabbitMq` writes now time out.

**`Lyric.Cache.Memcached`.** `Cache.CacheStore` on memcached 1.6.10 and later through a meta-protocol client on `Lyric.Net`, with no externs of its own, on dotnet and the JVM. memcached cannot enumerate keys, so `clear()` replaces a per-store generation that is part of every key and is read in the same write as each command. TTLs above 30 days are sent as absolute timestamps. TLS and memcached's ASCII authentication are supported; a single server only. Verified against memcached 1.6.24 (plain, TLS, authenticated), including `Testing.Conformance.Cache`.

**Issues filed:** #9071 (method syntax through an aliased import; `pub val` across packages), #9077 (dotnet: a generic called on the result of an imported protected type's entry is specialised for `Int`).

The book's chapter 29 matrix lists both packages.
