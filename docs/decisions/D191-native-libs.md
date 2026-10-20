# D191 - `[native.libs]`: C libraries a native program links, with dependency propagation

**Status:** accepted, implemented for `--target native` (docs/67 phase G3, #7942); realises the `dir` and `pkg_config` sources of docs/67 §6

## Decision

1. **Declaration.** `[native.libs.<name>]` tables in a project manifest name a C library and
   exactly one source: `dir` (a directory relative to that manifest holding `lib<link>.so`,
   `.dylib` or `.a`) or `pkg_config` (a system package, with `version` as its minimum). `link`
   overrides the `-l` name. Anything else is a manifest error.
2. **Resolution.** `Cli.resolveNativeLibs` turns the declarations into clang link arguments
   (`-L`, `-l`, or the `-L`/`-l`/`-Wl` flags `pkg-config --libs` prints) and the list of shared
   files to ship. The emitter passes a link argument written with a leading `-` through
   unchanged; a bare name is still `[native].extra_libs`' `-l<name>`.
3. **Propagation.** A path or workspace dependency's `[native.libs]`, and those of its own
   dependencies, join the application's. A library named twice resolves once, from the
   declaration nearest the application. This is the "link requirement reaches the application"
   half of docs/67 §6, so a binding library carries what it needs.
4. **Bundling.** The shared files of a `dir` library are copied next to the executable and the
   link adds `-Wl,-rpath,$ORIGIN` (`@loader_path` on Darwin triples), so the program runs from
   its output directory without the original library directory. System (`pkg_config`)
   libraries are not copied.
5. **Cross-package externs.** A `pub extern func` is now visible to other packages of a
   project (and a `pub` one to stdlib importers). A bindgen kernel package is nothing but
   externs and could not be imported before.
6. **Foreign records in libraries.** `foreign record` (D188) is allowed in a file annotated
   `@unsafe_ffi` at file level, not only in stdlib `_kernel_native/` packages, which the mode
   checker never sees; bindgen emits the annotation.

## Not in this slice

Prebuilt per-triple archives restored by `lyric restore` with SHA-256 checksums in
`lyric.lock`, and macOS `.app` bundling, are the next slice of G3.
