# docs/70 phase 3a: `toString()` on a range subtype or distinct value builds as the built-in `toString` (D406)

`c.toString()` on a range-subtype or distinct value records no callee; it now builds as the built-in `toString` of the value, so the body is no longer counted (I0002), in the declaring package and in a consumer of a restored one. New shape `range_to_string_method`.
