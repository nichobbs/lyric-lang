# D204 - Follow-ups to the native graphics phases: generic helpers, enum patterns, wrapped text areas

**Status:** shipped (#8417, #8421, #8422 part); supersedes the last sentence of D201 ("Not in this slice"), which called `frameLoop` and `drawFrame` `pub` for #8417

## Decision

1. **A generic function's private helpers travel with it on native (#8417).** Instantiating a generic
   from another package compiles its body in the caller's package. The native backend appended only the
   *visible* generics of a package to its output for codegen to instantiate, so a `pub` generic that called
   a private generic of its own package failed with `N0007` ("cannot resolve call target"). Every generic
   with a body is now appended, private ones included (`MiddleEndOptions.genericItemsOut`). A private
   non-generic helper already resolved on native, where the whole program is one module.

   The rule is not the same on every target, and this entry does not make it so:

   | | private generic helper | private non-generic helper |
   | --- | --- | --- |
   | `--target native` | works | works |
   | `--target jvm` | works (source packages) | rejected, now with the T0123 message below |
   | `--target dotnet` | rejected (T0123) for a restored package | rejected (T0123) |

   A `.NET` consumer calls a restored package through contract metadata, which carries the bodies of
   `pub` generics only, and a private method of another assembly cannot be bound. Portable code makes the
   helpers a `pub` generic calls `pub`. The JVM no longer reports the case as an internal "unresolved call"
   but with the T0123 text the dotnet backend uses: the call, the generic's package, the package it was
   specialised into, and "make it `pub`". Carrying private helpers in contract metadata (so dotnet accepts
   what native and the JVM accept) is tracked with a plan in the follow-up issue linked from the progress
   entry (#8427); it needs the metadata format of docs/45 to hold non-visible generics that name
   resolution ignores, and unique names for them, since Mono keys imported generics by bare name.
2. **A bare enum case in a pattern compares against the scrutinee's own enum on native (#8421).** Native
   reduces an enum to its ordinal and resolved a bare case name in `match` bundle-wide, first enum wins, so
   two enums sharing a case name miscompiled whenever the scrutinee was not a plain local with a declared
   type (a field access, a call result, a nested pattern). The type checker already knows the scrutinee's
   type; it now records the enum of each bare case pattern it resolves
   (`SymbolTable.enumCasePatternSites`, keyed by the pattern's span) and the pipeline qualifies the pattern
   with it (`qualifyEnumCasePatterns`: `case Select` becomes `case Ui.Core.WidgetKind.Select`) before
   monomorphisation, native only. The qualified spellings `lyric-ui` used as a workaround are bare again.
   Bodies of a generic from another package are qualified when that package is compiled, not at the call.
3. **Text areas wrap and scroll (#8422).** `Ui.Native.Wrap` (host-free, tested on every target) cuts a text
   into visual lines at newlines and again at the box width (after the last word that fits; a word wider
   than the box breaks between code points; trailing spaces hang). A text area is as tall as its wrapped
   lines between 88 and 264 logical pixels and scrolls beyond that. The caret moves by visual line (Up,
   Down, PageUp, PageDown keep their column), Home and End go to the edges of the visual line, a click or
   drag places it by row and column, a triple click selects the line between newlines, the selection is one
   band per line, and text being composed by an input method is underlined across lines. A caret at a cut
   is shown at the start of the next line, so the end of a cut line is one code point short.
4. **HiDPI.** Fonts are opened at the display's scale, so the painter measured carets, selections and line
   heights in device pixels while placing them in logical ones. `PaintCtx` now carries the scale and
   measures in logical pixels. The goldens are all at scale 1 and are unchanged.

## Not done, and where it is tracked

- Link-time pruning of unused `@library` kernels (a native app that depends on `Lyric.Ui` links
  `-lwebview`): needs reachability-based lowering of dependency packages, including record methods and
  protected types, which today are lowered only for the project's own packages (#8429, also #8413).
- Accessibility through AccessKit (#8430), a macOS surface (#8401, #8419), bidirectional text and carets
  (#8410), the multi-threaded coroutine scheduler (#7947).
- The native backend has no or-patterns (`case A | B`), found while testing item 2 (#8428).
