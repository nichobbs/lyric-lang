# wasm32 component: async exports (docs/35 W4 follow-up)

An `async func` can be exported from a component (D-progress-1043): the generated wrapper
drives the task to completion, sleeping out its timers, so the host call blocks; the build notes
each such export as `W0041`.

- Q-JS-006 is resolved for v1 as the synchronous subset.
- Test: a component with async exports (sleeping, `String`, `Long`, `Option`, no suspension)
  run through `jco` under node, the call measured to wait for the sleep.
