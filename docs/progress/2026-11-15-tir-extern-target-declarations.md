# 2026-11-15 - TIR builder: @externTarget functions are body-less declarations (D473)

docs/70 §6.2, #8613. The placeholder body of an `@externTarget` function is no longer built; the function is described by its signature. This removes the ~19 stdlib JVM kernel bodies (`newList`, `newMap`, `newSet`, `hostAppend`, ...) that every JVM self-test's closure counted as I0002, about 1,200 of the self-tests area's 1,969.
