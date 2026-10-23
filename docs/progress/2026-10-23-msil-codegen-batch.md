# MSIL codegen batch: record-method Option arguments, impl `Self` spelling, `@` local patterns, `Map.containsValue`, `String.split`, arithmetic on untyped operands (#8273, #8313, #7803, #7977, #7191, #8344, #7676)

A batch of dotnet-emitter fixes from the `group:msil-codegen` triage.

- **#8273** A bare `None` (or an `Option[Int]` local bound to `None`) passed to a
  record or protected method's `Option[T]` parameter was built as the erased
  `Option_None<object>`, so the method's own `match` found no arm and panicked
  "match not exhaustive". The instance-dispatch call path now threads the
  parameter's generic arguments as the construction hint, exactly as the
  free-function path already did.
- **#8313** An `impl` method that spells the target type where the interface
  slot says `Self` (`func takeFrom(self: in Box, other: in Box)` for
  `func takeFrom(self: in Self, other: in Self)`) encoded its own `Box`
  signature, so the CLR found no implementation for the slot
  (`TypeLoadException`). `implSelfSpellingMsil` rewrites such a parameter or
  return type to `Self` from the interface method's registered declaration, so
  the slot's erased signature is encoded and the prologue narrows the argument
  as it does for a written `Self`; `in`, `inout` and return positions are
  covered.
- **#7803** `val whole @ (a, b) = pair` dropped the inner pattern of the `@`
  binding in the local-binding lowering of both backends (T0115 on dotnet,
  J008 on JVM): only a plain `PBinding(name, None)` takes the single-slot
  fast path now; an `@` pattern goes through the destructuring path that binds
  the name and lowers the inner pattern.
- **#7977** `Map.containsValue` had no MSIL route (T0120). It lowers to
  `Dictionary<K,V>.ContainsValue` for concrete and erased maps.
- **#7191** `s.split(sep)` bound the pure-Lyric `Std.String.split` by token and
  threw at run time when `Std.String` was not linked into the bundle. It now
  binds `String.Split(string, StringSplitOptions.None)` directly, so no bundle
  composition can leave it unresolved.
- **#8344** An arithmetic operator (`+ - * / %`) whose operand the MSIL
  lowering only knows as `object` no longer emits a numeric opcode on object
  references. It fails the build with a spanned `T0120` naming the operator,
  instead of producing unverifiable IL.
- **#7676 (part 1)** `ldfld`, `stfld` and `ldflda` on a generic instantiation
  share one TypeSpec and one field MemberRef row per (class, type arguments,
  field).

Verification: new self-tests `impl_self_spelling_self_test.l` (dotnet only: the
JVM backend has the same mismatch for interface-typed calls, tracked in #8426),
`local_as_pattern_self_test.l`, `record_method_option_param_self_test.l` and
`string_split_intrinsic_self_test.l` (dual-target), plus `containsValue` cases
in `map_enhancements_self_test.l`. All four are in the dotnet CI batch and the
`scripts/ilverify-selfhosted.sh` phase-4 list; the three dual-target ones are
also in the JVM batch.
