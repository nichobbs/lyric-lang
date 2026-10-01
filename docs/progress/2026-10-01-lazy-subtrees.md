# `Lazy` subtrees (docs/65 §13.5, D153)

The second slice of phase U6: a view can mark a subtree to be rendered
and diffed only when its fingerprint changes.

- **API.** `Widgets.lazyView(key, fingerprint, render)` builds the new
  `View` case `Lazy`. The author derives the `String` fingerprint from
  everything `render` reads.
- **Session.** After each render, `Diff.resolveLazy(tree, previous)`
  replaces each `Lazy` with a `Memo`, reusing the previous memo's subtree
  without rendering when the key and fingerprint match. A key repeated in
  the previous tree is never reused.
- **Diff.** Two `Memo`s with the same key and fingerprint produce no
  patches, and nothing below them is compared.
- **Transparency.** `Core.viewOf` unwraps both cases; event paths,
  `keyed`, `mapView`, `toWire`, `Ui.Html` and `Ui.Testing` use it, so
  hosts and the wire protocol are unchanged.
- **Tests.** `lyric-ui/tests/lazy_tests.l` (render counts across updates,
  patches on a fingerprint change, a click through a memo, wire and
  `Ui.Testing` transparency), on dotnet and the JVM.
- **Found on the way.** A `case _` arm placed above the `Element` arm in
  `Ui.Testing.collectText` hid every element's text without any
  diagnostic; the checker gap is #7916.
