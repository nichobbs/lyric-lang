# TIR builder: a primitive array an untyped host chain returns is the slice of its element (D753)

`val grown = Arrays.copyOf(src, 5)` builds: a host `int[]` result the checker left untyped is `slice[Int]` with `CvFromHost`, as where the checker types the call. The CI "genuine primitive array" negative test reaches the backend's loud failure again. Self-test: `tir_build_self_test.l`.
