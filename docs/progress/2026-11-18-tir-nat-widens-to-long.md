# docs/70 phase 3a: a Nat widens to Long (D453)

`toLong()` on a `Nat`-backed range subtype or distinct type builds as an unwrap followed by a `CvWiden` to `Long` instead of being counted as "a conversion method whose result differs from the underlying type" (I0002).
