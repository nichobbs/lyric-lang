# UI library: open questions resolved (D138), keyed events, session resume, field paths (#7390)

D138 resolves Q-UI-001 to Q-UI-010. Implemented (D-progress-980): event
paths address keyed nodes by key (protocol version 2), so a click on a row
that has moved or gone never reaches a different row; sessions survive a
dropped connection and resume within `reconnectGraceMs`, with
`maxSessions` evicting the longest-disconnected sessions first and a
per-session lock serialising reconnects against running effects;
`FieldError` carries a structured `FieldPath` and `DraftRows` gives list
rows stable ids. Compiler fixes found along the way:
- constructing another package's `protected type` now works on MSIL (it
  failed with T0123);
- a generic constructor checks its arguments against field types in the
  declaring package's scope;
- a Boolean left boxed (a call through a function-typed lambda parameter)
  is unboxed at every condition on MSIL, and in match guards on JVM. The remaining resolutions (`Ctx` shape,
layer purity rules, generator request schema v2, `raw` feature gate, JVM
desktop binding, runtime schema generation) are designs recorded for their
phases. `lyric-ui` still builds on MSIL only (#7378).
