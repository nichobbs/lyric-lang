# TIR builder: a `return` in a lambda takes the lambda's result type (D768)

An open `return` operand inside a lambda (`return Err(error = m)` in a generic function whose lambda's result type mentions the function's type parameter) is settled from the lambda's own result type, not left to the gate. Clears `renderRecording` in `lyric-game/platform/src/run.l`.
