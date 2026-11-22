# TIR builder: a slice is passed as the JVM's Object[] (D699)

A slice of any element passed for a host `java.lang.Object[]` (the varargs of `Arrays.asList`, `Objects.hash`, `String.format`) is built as a `CvBoxToHost` on the host array, as the JVM backend passes it. Self-test: `tir_build_self_test.l`.
