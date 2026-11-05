# Native lyric-ui: password inputs are masked (#8817)

The native lyric-ui host drew a password input's value, and the text an input method was composing for it,
as plain text, copied it to the clipboard on Ctrl+C and Ctrl+X, and moved through it by its UAX #29 word
boundaries, which showed where its spaces and punctuation were. Only the accessibility tree withheld it
(D214). The web and desktop hosts were not affected, as the browser masks `<input type="password">`.

`Ui.Native.Interact.isMasked` and `shownValue` now give the host what it draws of an input: for a password,
one bullet (U+2022) per code point, so every caret position of the value is the same position of the
bullets. `Ui.Native.Paint` draws the bullets for the value and the composition. `Ui.Native.Run` places
clicks, steps the caret and gives the input method its caret rectangle over the bullets, refuses copy and
cut, moves Ctrl+Left and Ctrl+Right (Alt on macOS) to the ends of the value, and selects all of it on a
double click.

Tests: a core test in `lyric-ui/native/tests/interact_tests.l` (dotnet and JVM). The customers example's
`--check` run and its golden frames are unchanged (it has no password input).
