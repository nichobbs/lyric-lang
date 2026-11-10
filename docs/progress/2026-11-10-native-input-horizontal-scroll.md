# Native lyric-ui: single-line inputs scroll to keep the caret visible (2026-11-10)

`Ui.Native.Run.revealCaret` now moves `TextEdit.scrollX` for text, number and date inputs after every edit,
caret move, click, drag, Tab focus and assistive-technology focus (#8813). The pure rule is
`Interact.scrollToCaretX`: the caret's visual x (`Wrap.offsetInRowAt`, which takes bidi and affinity into
account) stays 8 px inside the content box, the scroll never leaves the text's visual extent
(`Wrap.lineEdgesOf`, so a right to left value is measured from where its pieces are laid out), and text that
fits is not scrolled. Focusing an input starts from scroll 0, the way an unfocused input is drawn. Covered by
three cases in `interact_tests.l` (left to right, right to left and mixed values wider than the box). A
customers `--check` frame with a long value scrolled to its end is not added yet: it needs SDL3 and lavapipe
to record the golden image, which this change was not built with.
