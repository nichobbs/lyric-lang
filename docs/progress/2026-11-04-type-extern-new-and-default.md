# Typing extern constructors and default() (#8613)

D351.

- `T.new(args)` on an extern type is that type; `default()` adopts a known
  expected type. Non-callee silent sites: 386 -> 327.
