# Cross-target parity batch: `Map.add`, `print`/`println`, `toIsoString`, culture, collection `==`, native list insert (D204)

Group `group:stdlib-cross-target-parity`. The rules are recorded in D204; this
entry lists what shipped and how it is pinned.

- **`Map.add` replaces on dotnet (#7301).** `emitDictAdd` lowers to
  `Dictionary.set_Item`; `Add` threw on a duplicate key while the JVM and native
  replaced the value.
- **`print` takes any value, `println()` is legal (#7893, #7912).** The checker
  types `print` like `println` (`codegenBuiltinType`, `isCodegenBuiltinName`) and
  makes `println`'s argument optional (`builtinOptionalTrailingArgs`). The
  MSIL and JVM backends already lowered both; native gained `print(x)`
  (`lowerPreludeWrite`).
- **`toIsoString` has one form (#8314).** dotnet re-groups the seven digits of
  `DateTime.ToString("o")` into the none/3/6/9-digit form the JVM and native print.
- **Stringification is culture-invariant on dotnet (#7911).** `main` sets
  `CultureInfo.CurrentCulture` and `DefaultThreadCurrentCulture` to the
  invariant culture. `culture_invariant_self_test.l` runs under `de_DE` and
  `sv_SE` from `scripts/ci/println-stringify-e2e.sh`; before the change it
  failed there (`v=1,5`, a U+2212 minus sign).
- **`==` on tuples, `List`, `Map` and `Set` is structural on dotnet (#8169).**
  `(1, 2) == (1, 2)` was `false`. `emitStructuralCollEqMsil` compares inline
  (new `IDictionary` member refs). `stdlib_parity_self_test.l` pins it on both
  targets; the four `==` cases failed on dotnet before.
- **Native `xs.add(index, item)` (#7800).** New `lyric_list_insert` in
  `lyric-rt` with a C unit test, lowered in `lowerCollectionMethodCall`;
  `llvm_collections_self_test.l` covers insert, ARC for `String` elements and the
  out-of-range panic under ASan. The book's section 12.4 example is rewritten
  against the real `Std.Collections` API.
- **Verified, no change:** `Std.Set` on the JVM works since #7782 (#7312); a user
  `toString` on a distinct type wins over the builtin arm on both targets (#7354).
- **Still open:** a tuple as a bare `Map`/`Set` key on dotnet (#8170, needs a
  comparer or a tuple class with overrides), structural `toString` of records
  and collections (#7892), the JVM `Double.equals` element nuance (#8439).
