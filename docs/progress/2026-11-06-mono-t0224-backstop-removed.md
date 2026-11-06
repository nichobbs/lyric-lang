# Mono's T0224 backstop removed (D384)

After D383 the checker records package-qualified and method calls, so it is the
only source of T0224. `Lyric.Mono` reports an unpinned imported call it still
sees as the internal M0002 instead, never a silent drop. Remaining in #8760:
the exemptions of `unpinnedCallKeepsErasedDefault`.
