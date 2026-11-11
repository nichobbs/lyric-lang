# TIR builder: a protected member's bare field names (D576, #8613)

Docs/70 phase 3a: a protected type's type entry lists its fields, and the bare field names its `func`s and
entries use (`n = n + k`, `n`) build as reads and writes of the receiver `self`'s fields. Generic protected
types are still listed as failed. Phase 3a is not complete: I0002/I0003 do not stop the build yet.
