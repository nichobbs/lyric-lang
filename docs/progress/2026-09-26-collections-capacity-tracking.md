# Collections: native map capacity follows the live size; presized snapshots (#7282)

The native runtime's open-addressing map (`lyric-rt`) only ever grew. A map
that was filled and then mostly cleared kept its peak capacity, so
`mapKeys`/`mapValues` (and every `for` over their snapshots) walked every
peak-capacity slot to collect a much smaller live set.

- `lyric_map_remove` now rehashes to a fitted capacity (load at most 1/2) once
  the live set drops below 1/8 of capacity. It takes at least cap/8 removals
  to get there from the load any resize leaves, so the rehash is amortised
  O(1) per removal, and `lyric_map_keys`/`lyric_map_values` are O(len).
- The tombstone-purge rehash in `lyric_map_set` also rehashes straight to the
  fitted size when the live set is already far below capacity.
- The key and value snapshots allocate their output list once, at `len`.
- `Std.Set.setToSlice` presizes its buffer to the set's count on dotnet.

`lyric-rt`'s `test_map_shrinks_on_removal` fills 100,000 entries, removes all
but 100, and checks that capacity falls to at most 256, that survivors keep
their values, and that the drained map shrinks to the minimum table and can
be refilled.

`mapForEach`/`mapEntries` still re-look-up each key, which is one extra hash
probe per entry on a linear walk. A lookup-free walk needs an entry-enumeration
seam in each kernel (#7282).
