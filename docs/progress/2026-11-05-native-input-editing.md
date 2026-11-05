# Native lyric-ui: bidirectional single-line inputs, caret affinity, word movement (#8497)

Single-line inputs of the native lyric-ui host are laid out, painted and edited as one unwrapped line of the
text-area machinery (`Wrap.singleLine`), so Hebrew and Arabic in a name or other field are reordered and
stepped through by screen position. A position at the boundary of two pieces now has two caret places
(`TextEdit.downstream`) and Left and Right visit both. Ctrl or Alt with Left and Right move by word using UAX #29
word boundaries in any script, and a double click selects the UAX #29 segment under it (D413). The customers
example's check run gains an input scenario with a golden frame; the six existing frames are unchanged.
