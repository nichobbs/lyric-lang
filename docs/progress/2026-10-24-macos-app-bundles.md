# macOS `.app` bundles and dylib install names for native builds (#8401 item 1, D230)

A native build of a project with a `[native.app]` manifest table, for a Darwin
target, now also writes `<output>.app` (`Contents/MacOS`, `Contents/Frameworks`,
`Info.plist`). The link adds an `@executable_path/../Frameworks` run path beside
`@loader_path`, and a bundled dylib whose install name is not `@rpath/...` is
staged as a re-named, ad-hoc-signed copy so the executable's recorded name
resolves to the bundled file (before this, a `dir` library built with a bare
`clang -shared` only worked on macOS while its build directory existed).

- Code: `Lyric.Manifest` (`NativeApp`, `NativeConfig.app`),
  `lyric-compiler/lyric/cli/cli_native_libs.l` (`stageDarwinDylib`,
  `infoPlistText`, `assembleMacApp`, `macAppFor`), both native build paths in
  `cli_build.l`.
- Tests: `native_libs_self_test.l` (manifest and `Info.plist` tests everywhere;
  a macOS-only build/run test of the bundle). Run on `macos-latest` by
  `macos-native.yml`.
- Docs: D230, language reference section 3.6, book chapter 13 and appendix B,
  docs/67 section 6.
- Not done: signing and notarisation (#8545), `.tar.gz` prebuilt archives
  (#8401 item 2, #8546).
