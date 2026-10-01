# Native project builds compile their Lyric dependencies from source (#7833)

`lyric build --manifest ... --target native` now compiles a project's
`path = "..."` and `{ workspace = true }` `[dependencies]` into the same
native build, closing docs/65 F-13's dependency half and #6815 item 1(b).

- **Resolution.** `resolveManifestDependencies` treats native like the JVM
  (`compilesDepsFromSource`): a path dependency's DLL no longer matters, and
  the transitive walk (`collectTransitiveDepSources`) collects every reachable
  path and workspace dependency once. `buildProjectFromManifest` folds those
  packages into the native package list.
- **Features.** Each dependency package is `@cfg`-erased with its own
  manifest's features. `emitNativeProject` takes the resolver's
  `depPackageFeatures`, and `NativeSourcePackage.features` carries them to
  `compileProjectToNativeWithFlags`'s parse step. The project's own packages
  keep the build's features.
- **Unsupported dependencies.** A registry or git dependency, declared by the
  project or by a dependency it reaches, has no local source; native reports
  it and fails (`ResolvedManifestDeps.hadUnsupportedDep`). `[nuget]` and
  `[maven]` tables produce a warning instead of the NuGet-restore warning.
- **Unchanged.** A single-file native build still compiles only its own file.
  Generic protected types on native remain #7864.

Tests: `native_dependency_self_test.l` (a workspace where a native app calls
into a path dependency, its own path dependency and a workspace member, with
the dependency's default feature in effect; a direct and a transitive
registry dependency refused), wired into `scripts/ci/native-backend-self-tests.sh`.
