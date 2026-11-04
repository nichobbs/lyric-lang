# Typing default() (#8613)

D351.

- `default()` adopts a known expected type. Non-callee silent sites: 386 -> 355.
- Extern `.new` results are deferred to host-hierarchy assignability for
  extern types (CI found two JVM sources that rely on extern upcasts).
