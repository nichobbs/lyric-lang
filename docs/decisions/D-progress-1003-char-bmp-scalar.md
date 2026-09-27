# D-progress-1003 — `Char.fromInt` rejects surrogates (#7252)

**Status:** shipped

Finishes the item D-progress-998 left open on #7252.

## Decision

- **A `Char` is a BMP scalar value.** The language reference already says
  so (§1 character literals, §2.1 `Char` row: U+0000..U+FFFF excluding
  U+D800..U+DFFF). `Std.Char` now enforces it rather than treating a `Char`
  as an arbitrary UTF-16 code unit.
- **`fromInt` rejects surrogates.** Its precondition is now
  `n >= 0 and n <= 0xFFFF and (n < 0xD800 or n > 0xDFFF)`. A surrogate is a
  `PreconditionViolated` Bug like any other out-of-range input.
- **New `tryFromInt(n): Option[Char]`** (`@experimental`), the non-panicking
  form. It follows the `fromEpochMillis`/`tryFromEpochMillis` pair from
  D-progress-998.
- **Supplementary-plane text goes through `Std.Encoding.codepointToString`.**
  A code point above U+FFFF has no `Char`, so no caller builds one surrogate
  half at a time any more. `codepointToString` already requires a scalar
  value and has kernel twins on dotnet, the JVM and native.

## Migrated decoders

Each one combines a valid high+low surrogate pair into one code point. A
lone or reversed surrogate follows the decoder's existing error style:

| Decoder | Lone or reversed surrogate |
|---|---|
| `Std.Xml` numeric character references | `XmlError`. XML already rejected surrogate references (#7251). |
| `Std.Yaml` `\uXXXX` escapes (JSON and double-quoted YAML) | `UnexpectedChar`. Previously each escape became its own code unit, so a pair only came out right by adjacency, and lone surrogates got through. |
| `JsonRpc.Json` string escapes | `LoneSurrogate`, unchanged. Only the pair assembly changed. |
| `JsonRpc.Stdio` Content-Length body and header reader | U+FFFD. The byte count is the 3 bytes `encodeUtf8` already charged. A body that ends on a high surrogate is still a framing error. |
| lyric-auth JWT claim `\uXXXX` decoding (dotnet and JVM kernels) | U+FFFD, unchanged. Only `appendCodepoint` changed. |
| lyric-generator-sdk `parseJsonString` | U+FFFD. Previously each escape became its own code unit. |
| lyric-docker `jsonUnescapeValue` | U+FFFD. Previously each escape became its own code unit. |
| `Lyric.Lsp` frame reader (UTF-16 code units from the console) | U+FFFD. An emoji in an LSP message would otherwise have hit the new precondition. |
| `Jvm.ClassReader` modified UTF-8 (CESU-8 surrogate halves) | U+FFFD. A class name or member name with a supplementary-plane character would otherwise have hit the new precondition. |

The remaining `fromInt` callers pass values that are always in range:
ASCII or byte values in `http_server.l`, `fmt_core.l`, `llvm_ir.l`,
`metadata_reader.l` and `zip_reader.l`, and BMP-only arithmetic. The lexer
builds string-literal surrogate pairs through `CharHost.hostIntToChar`
directly. It never calls `fromInt`, and its output is a well-formed pair.

## Out of scope

The language reference still contradicts itself. §12.1's `s[i]` returns the
UTF-16 code unit at index `i`, and string iteration and the unchecked
`Int.toChar()` conversion can also yield a surrogate half. All three
produce `Char` values that §2.1 says cannot exist. That is #7505 (keep `Char` a BMP scalar; D-progress-1006), left to
a separate issue. `encoding_tests.l` relies on `Int.toChar()` to build the
lone surrogates it feeds to `encodeUtf8`.
