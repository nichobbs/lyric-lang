# Library census: Maven restore before JVM builds, JVM kernel twins in project builds (D695)

`library-tyerr-census.sh` restores each library's `[maven]` jars before its JVM build, so the host metadata resolves Undertow, Jakarta Mail and gRPC calls and the gate no longer stops those kernels; a JVM project build reads the `std/_kernel_jvm/` twin of a kernel file a package entry lists (`Lyric.Discovery.jvmKernelTwin`), as the source loader does, so `lyric-stdlib/lyric.toml --target jvm` is a JVM build. Clears the six JVM library builds #9282's census listed as stopped.
