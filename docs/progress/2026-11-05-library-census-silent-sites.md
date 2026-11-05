# The ecosystem census and the last silent TyError shapes (#8613)

D355.

- Running the I0001 gate (`LYRIC_TYERR_GATE=1`, W0036) over every library
  manifest on both targets found 92 silent sites in 11 packages that the
  compiler and stdlib census did not cover. They are now typed or named:
  config field reads (`Cfg.ttl`), enum and union cases named through their type
  or package (`LogLevel.Info`, `Std.Http.GET`, `PluginIssueKind.BadContributions`),
  a package's own enum shadowing an imported one, package-qualified `extern
  type` receivers and `.new`, a value-position `try` joining its body and
  handler types, erased generic field reads and context-typed generic calls
  (`default()`), calls on unchecked receivers, and a shared enum case name read
  without an expected type.
- Census after: compiler and stdlib closure 0, every library manifest 0 on
  dotnet and the JVM. Loop used: `for each lyric-*/lyric.toml` and `--target
  dotnet|jvm` with `LYRIC_TYERR_GATE=1 lyric build --manifest ...`, counting
  W0036.
- The native bridge stays resolver-free: no native kernel declares an `extern
  type`, so there is no host type to read (#8825 closed).
- Not changed: `lyric-ui` on `--target jvm` reports `M0004` for six imported
  generic calls on main as well; tracked separately.
