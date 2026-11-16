# 2026-11-16 - TIR builder: the JVM bridge registers restored JAR interfaces (D527)

docs/70 phase 3a, #8613. `Jvm.Bridge` reads `META-INF/lyric/*.lyri` of each restored JAR into one `DepDefaults` store per build, shared by every package's middle-end options, so a call that leaves out a restored package's defaulted argument builds on `--target jvm`. `restored_default_args_self_test.l`: 9 to 11 of 20 consumer builds. Open: JVM sibling check order, interface and `impl` member defaults, the native bridge (all in D527).
