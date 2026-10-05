# Native: the lyric-ui desktop host runs; `examples/ui-customers` builds (#8155, #7990)

- With `libwebview` installed (`scripts/ci/install-webview.sh`, WebKitGTK 4.1), `examples/ui-customers` links with
  `--target native`, and `lyric-ui/e2e/desktop-probe` opens a real webview window under Xvfb and reports its data
  grid's viewport: the desktop host runs end to end on native, as on dotnet and the JVM.
- `scripts/ci/ui-desktop-e2e.sh --target native` builds the example, builds the probe against a private `lyric_rt.a`
  and runs it; the `native-backend-self-tests` job runs it as one step.
- A function value naming the package's own function (the probe's `run(e)`) is no longer rejected as an overload when
  the only other arity is a same-named function of a package imported just under an alias (`Desktop.run/2`). Such an
  import is no longer counted as a bare import (`fileImportPackages`).
- Test: a case in `llvm_project_self_test.l`.
- Closes #8155 and #7990.
