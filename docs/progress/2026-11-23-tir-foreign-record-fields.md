# TIR: every field of a foreign record is writable in place (D778)

The TIR symbol table lists every field of a `foreign record` as writable, as the language reference does (T0180 judges the write), so `entry.buffer = ...` on a bindgen record verifies. Clears the I0003 on `lyric-gpu` `buildBindGroup` in the native build.
