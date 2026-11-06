# A distinct type's constructor call is typed (D357)

`Score(42)` for `type Score = Int` is now a `Score` to the checker, with its
argument checked against the underlying type. It was a silent `TyError`, found
by running `lyric test` over the compiler's self-tests with the I0001 gate on.
The census is partial; the classes it found and did not fix are listed in D357.
