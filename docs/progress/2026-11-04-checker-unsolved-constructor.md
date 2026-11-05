# The checker records a construction with an unsolved type argument (W0038) (docs/70 phase 3a, #8760)

D353, step one.

- A union-case construction whose arguments leave a type parameter of its union
  unsolved (`val r = Ok(value = 7)`) is recorded like an unsolved function call
  and reported as the warning W0038 at the end of the file, unless its expected
  type or the `?` propagate tables fix it.
- Census: no W0038 over the compiler and stdlib closure; CI's job logs are the
  census for the rest.
- Next: the error, then delete `ctorFill` and `importedFill` in `Lyric.Mono` and
  rewrite the Mono tests that pin the `Object` slots.
