# Library census: Maven restore before JVM builds (D695)

`library-tyerr-census.sh` restores each library's `[maven]` jars before its JVM build, so the host metadata resolves Undertow, Jakarta Mail and gRPC calls and the gate no longer stops those kernels; `lyric-stdlib/lyric.toml` declares `targets = ["dotnet"]`. Clears the six JVM library builds #9282's census listed as stopped.
