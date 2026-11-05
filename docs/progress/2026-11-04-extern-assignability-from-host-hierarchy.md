# Extern assignability from the host hierarchy (#8787)

D352.

- `ExternIterResolver.resolveBases` (MSIL metadata reader, JVM class reader);
  `externAssignable` in argument and binding checks; extern `.new` results are
  typed when a host resolver is present. Non-callee silent sites: 355 -> 327.
