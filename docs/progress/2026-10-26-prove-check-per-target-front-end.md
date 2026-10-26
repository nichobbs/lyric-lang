# `lyric prove --target jvm|native` checks the program with the target bridge's own front end (#8311)

`lyric prove` type-checks the program before proving it (#8227). For the JVM
and native targets that check used to run the MSIL bridge's front end with
JVM- or native-like options, so whatever the other bridges do differently
before codegen was not part of it. D262 moved the pre-check rewrite flags into
`Lyric.Pipeline.pipeExpandProfile`; this change finishes the issue by making
each target's check its own bridge's front end.

- `Jvm.Bridge`: the front of `compileProjectToJarBundledWithRestored` (parse
  and `@cfg` erasure per package, alias-dot-name canonicalisation, wire,
  config and plugin template collection and expansion, alias resolution, the
  `main(): Long|Double` rejection `J001`, the standard library parsed with
  invariant checkers and alias rewrites, the sibling and restored-dependency
  scopes) is now `jvmProjectFrontEnd`, and its import-closure walk is
  `jvmBundleClosure`. The build and the new `checkProjectTypesJvm` both call
  them, and both build their middle-end options with `jvmMiddleEndOptions`.
  The check runs the passes up to the mode check on the entry package and on
  every project package the build bundles, with the warnings of path
  dependencies quiet as in the build. A single file is a one-package bundle,
  as `lyric build --target jvm <file>` compiles it.
- `Lyric.LlvmBridge`: the fronts of `compileToNativeWithFeatures` and
  `compileProjectToNativeWithShape` are `nativeSourceFrontEnd` and
  `nativeProjectFrontEnd` (`@cfg` erasure by `target_os`, the component
  plugin expansion and shims, template expansion, alias resolution, module
  `val` hoisting, `parseNativeStdlib`). `checkSourceTypesNative` and
  `checkProjectTypesNative` run the passes up to the mode check with
  `nativeMiddleEndOptions`, the builds' own options, and then the build's
  `N0025` for a `config { }` block. The check is for the host and an ordinary
  binary.
- `Lyric.Pipeline` gains `pipeParseAndEraseTo`, `pipeExpandAndRewriteForTo`,
  `pipePluginExpandForComponentTo` and `pipeGateTo`, the sink-taking forms the
  bridges' front ends report through: printed for a build, collected for a
  check. The MSIL front end uses them too.
- `Lyric.Emitter.typeCheckProject` and `typeCheckSourceForFeatures` dispatch by
  target to `Msil.Bridge.checkProjectTypes`/`checkSourceTypesForFeatures`
  (now dotnet-only, without a target parameter),
  `Jvm.Bridge.checkProjectTypesJvm` and the native entries. The JVM build and
  check share `jvmProjectInputs`, so the check is given the project as the
  build is; that also fixes a JVM check of a project with restored
  dependencies, which loaded the JARs with the dotnet DLL reader
  (`loadRestoredArtifactsJvm` is now the one JVM loader). The native check
  merges a package's files with the `target_os` feature, as the native build
  does (`nativeProjectInputs`, shared with `emitNativeProjectWithShape`).

The standard-library packages a JVM or native build bundles are type-checked
by that build, not by `lyric prove`: they are the toolchain's, not the
program's (docs/01 §"Build flags" of `lyric prove`).

`scripts/ci/prove-type-check.sh` gains two programs that only one target's
build rejects before codegen: `examples/prove-type-check/main_long.l` (proved
on dotnet, `J001` at `main` on the JVM, as `lyric build --target jvm` reports)
and `examples/prove-type-check/config_block.l` (proved on dotnet and the JVM,
`N0025` at the block on native, as `lyric build --target native` reports).
