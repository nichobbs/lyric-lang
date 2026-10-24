# JVM and FFI binding batch (#8528, #8089, #7868, #8242, #8482, #7175, #7511)

JVM:

- **Frame gaps (#8528).** The frame builder skipped a local slot that was allocated but never stored (lowering that
  was abandoned after it reserved temporaries, such as an argument coercion of a nested constructor), so every later
  local shifted onto the wrong slot and the class failed verification. A gap is now a `top` entry, and trailing
  ones are trimmed. `JDataIn.new(JBytesIn.new(bytes))` in a `try` body now verifies.
- **Restored generic functions (#8089).** A restored dependency's generic `pub func` is dropped from its JAR by the
  library's own monomorphisation, and the JVM consumer never specialised it, so a call died with `NoSuchMethodError`
  or `NoClassDefFoundError: Rd/Lib/T`. The JVM bridge now feeds the restored packages' generic functions to the
  monomorphizer, as `Msil.Bridge.collectRestoredGenericFuncs` does, so each call specialises a copy of the contract's
  body in the consumer.
- **Receivers in another package's generic (#7868).** A specialised copy of another package's generic carries that
  package's spans, which the consumer's check never saw, so the JVM could not narrow an erased receiver
  (`o.isSome` on an `Option[M]` parameter was J007). `Lyric.Pipeline.foreignMemberRecvClasses` checks those bodies in the
  declaring package's scope and records the receiver classes under `<origin>|<siteKey>`; the JVM looks them up in the
  copy's scope (`originScopedExternTypes`).
- **#8242** (nested generic and function-typed call results) no longer reproduces on `main`; its two shapes are now
  regression tests.
- **#7175.** A restored plain and generic `exposed record` constructs and reads fields on the JVM too; pinned by test.
- **#7511.** `encoding_tests.l` and `xml_tests.l` run on the JVM in the JVM generics batch. The generator SDK suite is
  already in the JVM ecosystem suites. The Docker suite compiles; its one JVM failure is the missing Unix-socket HTTP
  transport (a real gap, tracked separately).

MSIL auto-FFI:

- **Narrow and unsigned integer parameters (#8482).** An `Int` or `Long` argument narrows to a `SByte`, `Int16`,
  `UInt16` or `UInt32` parameter with `conv.ovf.*`, so a value outside the range throws `OverflowException`; a `Long`
  is the bit pattern of a `UInt64`. The scorer admits these below every widening match.

Tests: `nested_generic_result_jvm_self_test.l` (JVM generics batch), `restored_default_args_self_test.l` (restored
dependency batch), `auto_ffi_self_test.l`.
