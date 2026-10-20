# `[native.libs]` and dependency link propagation (docs/67 G3 S4, #7942, D191)

- Manifest: `[native.libs.<name>]` (`dir` or `pkg_config`, `version`, `link`), validated.
- `Cli.resolveNativeLibs` / `bundleNativeLibs` (`cli/cli_native_libs.l`): link arguments,
  `$ORIGIN` run path, shared libraries copied beside the executable. Wired into single-file and
  project native builds.
- Dependencies: a path or workspace dependency's libraries (transitively) join the build.
- Pipeline: `pub extern func` is a cross-package item.
- Mode checker: `foreign record` allowed in a file annotated `@unsafe_ffi`.
- Tests: `native_libs_self_test.l` builds a C library, binds it with bindgen in one project,
  and builds a separate application that depends on it, runs it, deletes the library's
  directory and runs it again from the bundle; plus manifest and missing-directory cases.
- Docs: D191, language reference §3.6, book chapter 13 and appendix B.
