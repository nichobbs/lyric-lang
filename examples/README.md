# Examples

Self-contained Lyric programs that compile + run end-to-end through
the bootstrap `lyric` CLI.

```
$ lyric run examples/csv.l
$ lyric build examples/primes.l && dotnet exec examples/primes.dll
```

| Program          | Demonstrates |
|------------------|--------------|
| `csv.l`          | String indexing, BCL `String.substring`, `var` mutables, polymorphic `println`, while-loop CSV split |
| `fizzbuzz.l`     | Modulo arithmetic, if / else if cascade, `println(Int)` polymorphism |
| `primes.l`       | `@pure` annotation, trial-division primality, short-circuit `and` |
| `wordcount.l`    | Char comparisons, multi-counter mutable bookkeeping, string-walking |

Each program exists to surface gaps in the language surface — when
something doesn't compile, that's a real issue worth a PR rather
than a "the program is wrong" answer.

## Build cache

`lyric build` is incremental: a `.lyric-cache` sidecar next to the
output PE records a hash of the source, every reachable
`lyric/std/*.l` file, and the CLI binary's mtime.  Re-running the
same `lyric build` skips the emit; pass `--force` to rebuild.
