# `for` over an extern type is typed from the host's iteration protocol (#7809, D302)

A `for` over an `extern type` of no type parameters or of two or more used to
type its loop variable `TyError` (every body error involving it was hidden) and
accepted types that are not iterable. The element type is now read from host
metadata by each backend bridge and handed to the checker:

- **Checker** (`Lyric.TypeChecker`): `SymbolTable.externIterElems`
  (`ExternIterInfo`/`ExternIterElem`), `forIterElemType`'s extern arm
  (`externIterLoopElem`), the new **T0219** (host element type with no `extern
  type` in scope) and **T0126** for a host type that is not enumerable.
- **MSIL**: `Msil.MetadataReader.iterProtocolOfExtern` (InterfaceImpl/TypeSpec
  walk with generic substitution, across assemblies), `Msil.Bridge.
  MsilHostIterIndex` (an `ExternIterResolver`), and the `IEnumerable` enumerator lowering for marked
  loops.
- **JVM**: `ClassInfo.signature` and `parseClassSignature` in
  `Jvm.ClassReader`, `Jvm.AutoFfi.iterProtocolOfExternJvm`, `Jvm.Bridge.
  JvmHostIterIndex` (an `ExternIterResolver`).
- **Middle end**: `MiddleEndOptions.externIterResolver`,
  `Lyric.Mono` marking (`__lyric_host_iter`) and typed loop-variable binding.

Tests: `typechecker_self_test.l` (seven checker cases), `metadata_reader_self_test.l`
(six protocol-walk cases against the reference pack), `extern_iter_self_test.l`
(dotnet) and `extern_iter_jvm_self_test.l` (JVM) run the loops and use the
elements. Docs: language reference "for" section, book ch. 13 section 13.9.2 and
appendix B, docs/42 section 5.10, D302.
