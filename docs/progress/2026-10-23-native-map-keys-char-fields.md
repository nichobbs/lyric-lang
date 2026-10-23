# Native: structured Map keys and Char record fields (#8167, #7891)

- A `Map` key that is a union, a value record or an `Equals`-deriving heap
  record, or an `array[N, T]` works on native (#8167). `lyric_map_new_custom`
  takes a hash and an equality function over the key slot; the backend
  synthesises one pair per key type (`emitValueHashN`, mirroring
  `emitValueEqN`, so both zeros and every NaN hash alike and a union or record
  hashes by case and fields). Tuple, list, map and closure keys stay N0007;
  `Set` stays unlowered.
- A `Char` read from a non-generic record field (`r.c`, `self.c`, `a.b.c`)
  and a `Char` in `"${...}"` interpolation print as the character, not the code
  point (#7891 item 4). Before, `println(r.c.toString())` printed 113 for `'q'`.
