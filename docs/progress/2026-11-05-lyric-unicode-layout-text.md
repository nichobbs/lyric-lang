# lyric-unicode, and lyric-text's layoutText reorders mixed-direction paragraphs (#8496, #8410)

The Unicode 15.1 tables, UAX #9 and UAX #14 moved out of the native lyric-ui core into a new library,
`lyric-unicode` (`Unicode.Data`, `Unicode.Bidi`, `Unicode.LineBreak`), with their unit tests and
Unicode's conformance suites; the core and `lyric-text` depend on it. `Text.layoutText` now resolves
embedding levels per paragraph, breaks lines at UAX #14 opportunities, shapes each run in its own
direction and places each line's runs in visual order, right-aligning right to left paragraphs (D372).
The existing Latin/Arabic/CJK scene is byte-identical; the shape example gains mixed-direction and
line-breaking checks (which the old layout fails) and a second golden image, compared on the Linux,
macOS and Windows text lanes. `lyric-unicode` runs in the ecosystem-tests matrix on dotnet and the JVM,
and its conformance suites on native in `ui-native-e2e.sh`.
