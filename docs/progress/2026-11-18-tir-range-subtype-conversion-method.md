# docs/70 phase 3a: a numeric conversion method of a range subtype builds (D428)

`p.toInt()` on a `UInt`-backed range subtype builds as the underlying primitive's built-in on the unwrapped value, so the body is no longer counted (I0002).
