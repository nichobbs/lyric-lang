# 2026-11-15 - TIR builder: function values for host functional interfaces, records for extern interfaces (D470)

docs/70 §6.2, #8613. `Thread.new({ -> ... })` and a Lyric record that `impl`s an extern interface passed as that interface now take `CvBoxToHost`. The JVM "no host overload fits" kind over the stdlib JVM tests is gone (6 to 0).
