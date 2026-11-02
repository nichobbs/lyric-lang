# Verifier: a slice element read is a fresh value again (#8394)

#8725 made an element read of an array or a slice `select` of its elements,
on the premise that a slice is immutable (docs/01 §2.7). The type checker
accepts an element write to a slice, though, and on dotnet and the JVM the
write is seen through every binding of the slice, including a caller's `in`
argument:

```lyric
func g(xs: in slice[Int]): Unit {
  var s = xs
  s[0] = 99
}
```

leaves the caller's `xs[0]` at 99. With `select`, two reads of `xs[0]` on
either side of `g(xs)` were proved equal. A slice's element is now a fresh
value at each read, as it was before #8725, still with the element type's
range and width; an array's stays `select` (arrays copy on every target, so
no alias sees a write), and a slice's length stays modelled (a write cannot
change it).

The checker is to reject slice element writes (T0157), as docs/01 §2.7
specifies; slice reads become `select` again once it does. Tests:
`verifier_self_test.l`, "slice-element-not-a-value",
"slice-written-through-an-alias" and "slice-element-range".
