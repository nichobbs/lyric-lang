# Native lyric-ui accessibility tree (docs/67 G10, #8430, D214)

- `lyric-ui/native/src/access.l`: `Ui.Native.Access`: `buildTree` (roles, names, values, states, focus, selection, actions, grid and table indexes, modal dialogs, live regions), `diffTrees`, `resolveRequest`.
- `lyric-ui/native/tests/access_tests.l`: 17 cases, passing on `--target dotnet` and `--target jvm`.
- Not done, tracked in #8489: the AccessKit C binding (`lyric-access`), the platform adapters, the `Ui.Native.Run` wiring, the AT-SPI smoke test, the macOS VoiceOver smoke test.
