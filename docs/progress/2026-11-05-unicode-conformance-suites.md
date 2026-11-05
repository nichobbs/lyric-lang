# Unicode's BidiCharacterTest.txt and LineBreakTest.txt run against the native text algorithms (#8498)

`lyric-ui/native/tests/unicode/` vendors the two Unicode 15.1.0 conformance suites (pinned by SHA-256,
with the Unicode licence) and runs every line of them against `Ui.Native.Bidi` and `Ui.Native.LineBreak`:
`lyric test` on dotnet and the JVM, and a native build of the same runner (`lyric build --target native`)
in `scripts/ci/ui-native-e2e.sh`. All 91707 bidi lines passed unchanged. The line break suite found three
differences, now fixed (D371): LB28a was missing, LB25 now uses the number tailoring the suite tests
(UAX #14 section 8.2 example 7), and LB13 forbids a break before IS again, since LB15c and LB15d are
Unicode 16 rules. 10274 of 10274 lines pass on dotnet, the JVM and native, and the core's own suites on
dotnet and the JVM.
