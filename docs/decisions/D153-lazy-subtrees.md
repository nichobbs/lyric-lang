# D153 — `Lazy` subtrees: an explicit fingerprint, memoised by the session

**Status:** accepted, implemented

Implements docs/65 §13.5 (the second slice of phase U6).

## Context

Every update renders the whole view and diffs it against the last one.
For a large subtree that rarely changes (a long list, a report), both the
render and the diff are wasted work. §13.5 sketched
`Lazy(key, deps, render)`, skipped when "a structural hash of `deps`" is
unchanged, which needs `derives Hash` (or equivalent) on model types.

## Decision

1. **The view names a fingerprint, not dependencies.**
   `Widgets.lazyView(key, fingerprint, render)` builds
   `Lazy(key, fingerprint, render)`, where `fingerprint` is a `String` the
   author derives from everything `render` reads: a version counter, an
   id plus an edit count, or a digest. Lyric has no general structural
   hash over arbitrary model types, and deriving one for every model type
   would make each update hash the whole dependency graph. An explicit
   fingerprint costs what the author chooses, and keeps the contract
   visible at the call site.
2. **The session memoises.** After each render the session resolves the
   tree (`Diff.resolveLazy(tree, previous)`): a `Lazy` whose key and
   fingerprint match a `Memo` in the previous tree reuses that memo's
   subtree without calling `render`; any other is rendered now and kept
   as `Memo(key, fingerprint, child)`. The session's current tree
   therefore never holds a `Lazy`.
3. **Diffing skips unchanged memos.** Two `Memo`s with the same key and
   fingerprint produce no patches, and nothing below them is compared.
   Any other pair is diffed by what it shows.
4. **Keys are unique within a view.** A key that occurs more than once in
   the previous tree is never reused; each occurrence is rendered every
   time. That is correct, only slower.
5. **Transparent everywhere else.** `Lazy` and `Memo` occupy their
   subtree's position: event paths, `keyed`, `mapView`, `toWire`,
   `Ui.Html` and `Ui.Testing` see the subtree they show (`Core.viewOf`).
   Hosts and the wire protocol are unchanged.

## Consequences

- `View` gains two cases. Code that matches `View` exhaustively must
  handle them (in practice by matching `Core.viewOf(v)`).
- A stale fingerprint shows stale content: the subtree is not rendered
  again until the fingerprint changes. This is the author's contract,
  stated on `lazyView`.
- `render` must be pure, as views already are; it may run at any render,
  or not at all.
