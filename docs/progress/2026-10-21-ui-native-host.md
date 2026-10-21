# The native `lyric-ui` host (docs/67 G10, #7949, D203)

- `lyric-ui/native/`: `Ui.Native.Theme`, `Client`, `Layout`, `Interact` (30 tests, every target).
- `lyric-ui/native/host/`: `Ui.Native.Paint`, `Ui.Native.Run` (window loop, headless harness) and the customers
  example (`examples/customers`) with golden frames.
- `lyric-draw`: `setScale` (logical pixels). `lyric-window`: `TextEditing` and `setTextInputArea` (IME).
  `lyric-gpu`: prefers unorm surface formats.
- `examples/ui-customers`: composition extracted to `Customers.App`.
- Compiler: nested nullary union case patterns on native (`nested_nullary_pattern_native_self_test.l`).
- `scripts/ci/ui-native-e2e.sh`, wired into `native-backend-self-tests.sh`.
- Docs: D203, docs/65 §13.3, docs/67, book chapter 31, lyric-ui README, CLAUDE.md. Open: accessibility (AccessKit),
  macOS, #8421 (enum case collisions), link-time pruning of unused `@library` kernels.
