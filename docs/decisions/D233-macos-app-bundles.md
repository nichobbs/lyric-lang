# D233 - macOS `.app` bundles for native builds

**Status:** accepted, implemented for `--target native` on Darwin triples (docs/67 phase G3 follow-up, #8401 item 1);
code signing and notarisation are a later slice

## Decision

1. **Opt-in by manifest.** A `[native.app]` table (keys `identifier`, `name`, `version`, all optional) asks for a bundle.
   A native build whose target is a Darwin triple (the host when `--triple` and `[native] triple` are unset) then writes
   `<output>.app` beside the executable. The table is ignored for every other target, so one manifest serves every
   platform. It is not the default for every Darwin build: most native programs are command-line tools, for which an
   `.app` is the wrong artifact. The parser does not see a table with no keys, so a bundle that wants only defaults
   names at least one key (`identifier` is the natural one).
2. **Layout.** `<exe>.app/Contents/MacOS/<exe>`, `Contents/Frameworks/<each bundled dylib>`, `Contents/Info.plist`. The
   loose executable and its dylibs stay where they were, so `lyric run`/`lyric test` and anything that reads the plain
   output path are unaffected.
3. **Run paths.** A build that bundles shared libraries now links with both `-Wl,-rpath,@loader_path` (beside the
   executable) and `-Wl,-rpath,@executable_path/../Frameworks` (inside a bundle), so the same binary works in both places.
4. **Install names.** A dylib built with a bare `clang -shared` records its build path as its install name, and the
   executable that links it records that name; the bundled copy would not satisfy it (D191's `@loader_path` run path only
   helps a library that names itself `@rpath/...`). For a Darwin `dir` library (and a restored prebuilt one) whose install
   name does not begin with `@rpath/`, the build stages a copy under `.lyric/native/_dylibs/<name>/`, rewrites its install
   name to `@rpath/<file>` with `install_name_tool -id`, signs it ad hoc again (`codesign --force -s -`; rewriting the
   name invalidates the signature arm64 macOS requires), and links and bundles the copy. A library that already names
   itself `@rpath/` (SDL3, wgpu-native) is used unchanged.
5. **Info.plist.** `CFBundleExecutable`, `CFBundleIdentifier` (default `lyric.<exe>`), `CFBundleName` and
   `CFBundleDisplayName` (default the executable name), `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` and
   `CFBundleVersion` (default the `[package]` version, else `0.1.0`), `LSMinimumSystemVersion` 11.0 (the first macOS on
   Apple silicon), `NSPrincipalClass` `NSApplication` and `NSHighResolutionCapable`. Values are XML-escaped.
6. **Not here.** Developer ID signing, hardened runtime, entitlements, notarisation and `.dmg` packaging: they need
   credentials CI does not have. Tracked in #8555 with a concrete plan.

## Verification

`native_libs_self_test.l` has a manifest test and an `Info.plist` test that run everywhere, and a macOS-only test that
builds the fixture application with `[native.app]`, checks the layout, runs `plutil -lint` on the plist, reads the
bundled dylib's install name with `otool -D`, deletes the library's original directory and the loose output, and runs
the executable from `Contents/MacOS`. The `native-platforms.yml` workflow runs it on `macos-latest`.
