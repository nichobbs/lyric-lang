# Language server: method-call navigation, standard-library check, proof gating (#8338, #8304, #7680)

- Hover and go-to-definition work on a method-syntax call to a dot-named function (`b.extra()` for
  `func Bag.extra(self: in Bag)`), on user types and primitives. The receiver's type is read from its declaration
  above the call (a parameter, an annotated binding, a `val x = Type(...)` constructor call, or a string/integer
  literal), and the function is bound as the type checker binds it: the type's own package first, then the nearest
  imported extension, then the standard library (hover only; the server has no file for it). When the receiver's
  type cannot be told, the call resolves only if exactly one function of that name exists. Hover shows the
  declaring package.
- The server's type check of an open document now loads the standard library the way `lyric build` does
  (`Msil.Bridge.stdlibImportedPackagesFromSources`, read once and kept), so `import Std.Collections` with `List[Int]`
  and `newList()` no longer reports false `T0010` / `T0020`.
- Because the check is trustworthy, the editor's proofs are gated like `lyric prove`'s (#8227): a document whose
  parse or check reports an error is not proved. The docs/01 section 13.3 exception is removed.
- `lspEncodeFrame` builds its frame with `encodeUtf8(header).concat(bodyBytes)` instead of a per-byte `List` copy.

Tests: four new cases in `lyric-compiler/lyric/lsp_self_test.l` (method hover and definition on user and primitive
receivers, an imported package's extension, a `Std`-importing document, proof gating); the existing framing cases
cover the encoder byte for byte.
