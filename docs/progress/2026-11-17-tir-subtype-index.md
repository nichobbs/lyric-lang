# docs/70 phase 3a: an index of a range subtype or distinct integer (D497)

`a[s]` with `s` a range subtype or distinct type over an integer is indexed through the explicit unwrap (`CvUnrefine`/`CvUnwrapDistinct`) instead of being counted as an argument conversion (I0002).
