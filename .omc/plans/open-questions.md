# Open Questions

## Epic #1877 Phase 2 — Closure Class Synthesis - 2026-06-24
- [ ] JVM typed functional interface strategy: synthesize one typed interface per signature shape, OR adopt `invokedynamic` + `LambdaMetafactory`? — Determines Stage 3 JVM design and class-count blast radius; needs a JVM-backend owner decision before Stage 3.
- [ ] Typed by-reference cell carrier: synthesize a dedicated `Lyric$Cell`/`__Cell` type, OR reuse 1-element typed arrays (`int[]`)? — Affects whether by-ref value-type captures box at all (Stage 4); arrays avoid a synthesized type but cost a bounds-checked access.
- [ ] Should Stage 5 (metadata-based delegate/SAM detection) ship inside Phase 2 or split to a follow-on epic aligned with #1622? — Stages 1-4 deliver the in-language zero-overhead value without it; Stage 5 couples Phase 2's timeline to docs/42 reader maturity.
- [ ] Class-count budget: is per-capturing-lambda type synthesis acceptable for large programs, or do we need lambda-class coalescing? — Affects metadata size; defer unless a real program shows a problem.
- [ ] Performance acceptance target: is "zero box on the monomorphic hot path" sufficient, or do we want an absolute throughput number vs. C#/Java equivalents to gate the phase? — Determines whether a benchmark harness is in scope for Stage 0.
