# 2026-09-27 — `Char.fromInt` rejects surrogates

D-progress-1003, #7252.

- **`Std.Char.fromInt`** now requires a BMP scalar value, so surrogates
  U+D800..U+DFFF violate its precondition. The new `@experimental`
  **`tryFromInt`** returns `None` for the same inputs.
- **Decoders that built astral characters one surrogate half at a time**
  now append the whole code point with `Std.Encoding.codepointToString`.
  They also no longer produce unpaired surrogates:
  - `Std.Xml` and `Std.Yaml`;
  - `JsonRpc.Json` and `JsonRpc.Stdio`;
  - the lyric-auth kernels, lyric-generator-sdk and lyric-docker;
  - the LSP frame reader and `Jvm.ClassReader`.

  A lone or reversed surrogate is a parse error in Yaml, Xml and
  `JsonRpc.Json`. Elsewhere it becomes U+FFFD.
- **Tests:** each decoder's existing suite covers a BMP escape, an astral
  pair, a lone high surrogate, a lone low surrogate and a reversed pair.
  `char_tests.l` covers the `fromInt` precondition and `tryFromInt`.
