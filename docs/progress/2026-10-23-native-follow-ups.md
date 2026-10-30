# Follow-ups to the native graphics phases (docs/67 G7, G8, G10; #8417, #8421, #8422; D268)

- Native backend: a generic with a body is always handed to codegen with its package, private ones too
  (`MiddleEndOptions.genericItemsOut`), so a `pub` generic that calls a private generic of its own
  package works from another package (#8417). `llvm_project_self_test.l` has the project-level case.
- Native backend: the type checker records the enum of each bare case-name pattern
  (`SymbolTable.enumCasePatternSites`) and `Lyric.Pipeline.qualifyEnumCasePatterns` qualifies it, so two
  enums sharing a case name no longer miscompile on a field access, call result or nested pattern
  (#8421). `native_enum_pattern_scrutinee_self_test.l` (7 cases) and a two-package project case; the
  qualified-pattern workarounds in `lyric-ui` (`kindName`, `forms_view`) are bare again, and
  `lyric-game/platform` no longer exports `frameLoop` and `drawFrame` for the compiler's sake.
- JVM backend: an unresolved call inside a generic specialised from another package reports the T0123
  message dotnet uses ("make it `pub`") instead of an internal-sounding one. Dotnet and the JVM still
  reject a private non-generic helper and dotnet a private generic one from a built package: the rule is
  in docs/01 §3.3, and carrying them is #8427.
- `lyric-ui/native`: `Ui.Native.Wrap` (soft-wrapped lines, caret by row and column, selection spans, scroll
  to caret; 13 tests on every target), `Interact.moveVertical`, `moveToLineEdge`, `paragraphAt`,
  `TextEdit.goalX`/`scrollY`. The host wraps and caches lines, places a click or drag by row and column,
  handles Up, Down, PageUp, PageDown, Home, End and the wheel in a text area, and the customers check types
  multi-line notes, checks the box grows and the caret moves by line, and compares a new golden frame
  (`notes`).
- `lyric-ui/native` fixes found on the way: a caret after a trailing space did not advance (a layout leaves
  trailing spaces out of a line's width), and carets, selections and line heights were measured in device
  pixels at a display scale other than 1 (`PaintCtx.scale`).
- CI: `native_enum_pattern_scrutinee_self_test.l` joins `native-backend-self-tests.sh`; the wrap tests run with
  the rest of `lyric-ui/native` in `ui-native-e2e.sh`.
- Filed with plans: #8427 (private helpers of a generic on dotnet/JVM), #8428 (native or-patterns), #8429
  (dependency packages lowered in full, `-lwebview`), #8430 (accessibility through AccessKit). Already
  tracked: bidi and UAX #14 (#8410), macOS surfaces and `.app` (#8401, #8419), the multi-threaded
  coroutine scheduler (#7947), Windows (#7948).
- Docs: D268, docs/01 §3.3, docs/05, docs/12, docs/65 §13.3, docs/67, native/plan/06, book appendix B (T0123) and
  chapter 31, lyric-ui README, CLAUDE.md.
