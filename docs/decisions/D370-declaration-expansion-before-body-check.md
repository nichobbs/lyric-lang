# D370 - Declaration expansion (derives, weaving) runs before body checking (docs/70 phase 3b, #8613)

**Status:** accepted. Design for docs/70 §7.1 and §13 phase 3b; the slices
below ship as separate PRs, each with its own entry.

## Context

Today the checker sees the source the user wrote. Derives (`deriveFile`),
monomorphisation and the weaver (`pipeWeave`) run after checking, on an AST
whose side tables (`*Sites`, keyed by `spanKey` = start:end offsets) have
already been spent. What they generate is therefore never checked:

- Derive output and woven wrappers are untyped AST that only a backend ever
  looks at, which is the "checker accepts, backend fails" bug class docs/70
  exists to remove.
- Every generated node carries `noSourceSpan()` (the weaver's `synSpan()`) or
  `syntheticSpan()` (derives), so diagnostics point at nothing and a debugger
  maps generated code to line 0.
- Weaver-synthesised calls (`__aspect_target`, `__lyric_bmode_*`, spliced
  template bodies) have no checker callee site, so 2d (#8612, D336) keeps
  name-based fallbacks for them.

Inputs are already syntactic. `deriveFileWithImports` reads only the file's
items plus the imported packages' type items (field types as written, distinct
type heads). The weaver reads aspect declarations, function signatures as
written (`matches:` globs, `signature:` returns strings), the
`TypeOwnerIndex`, and the collected cross-package templates. Neither needs a
checked body, and neither needs a second signature pass: the resolver
(`Lyric.Resolve`, D313) is built from the files, so generated items placed in
the file are collected, given DefPaths and entered in scope by the same code
that handles user items.

## Decision

1. **Placement.** One new step, `pipeExpandDeclarations`, runs at the head of
   `pipeCheckFront`, after the syntactic expansions (`pipeExpandAndRewrite`) and
   before `checkWithImportedPackages`. It maps `SourceFile -> ExpandResult
   { file, diagnostics, origins }` and runs derives, then the weaver (derive
   output can carry aspect-matched functions; the weaver never produces
   `@derive`). The checker, mode checker, contract elaborator, `?` lowering and
   mono then see a file that already contains every generated item and treat it
   as user code. Mono is unchanged: a generic woven function is now an ordinary
   generic wrapper over an ordinary generic target, which deletes the
   `specialiseWovenContracts` / `pipeWovenGenerics` special case in the last
   slice. The expansion runs per package after files are assembled (as the
   weaver does today), because a `matches:` glob and a template reach across
   files.

2. **Names.** Generated items are plain AST declarations in the file, so
   `Lyric.Resolve` collects them (a DefPath per item, scope entries from the
   file's imports). A generated reference to a name the user did not import is
   a missing import in generated code, so the expander adds the import to the
   file (as `injectWeaveImports` and the derive `Std.Json` injection already
   do) and to nothing else. The renamed target keeps the DefPath of
   `<name>__aspect_target`; the wrapper keeps the original name and signature,
   so every existing caller and every interface artifact is unchanged.

3. **Node ids.** Expansion runs before `renumberNodeIds` (D325: ids are given
   once, after the last expansion), so generated nodes are numbered with the
   rest and the TIR builder's per-node tables need no special case. A pass must
   not carry ids across a rewrite; expansion obeys this by running first.

4. **Spans, in two stages.** The end state (docs/70 §7.1) is that a generated
   node's span is the span of the declaration that caused it, because tables
   are keyed by `NodeId`. Until the checker's tables are NodeId-keyed (3a), the
   span-keyed tables need distinct spans per node (several hundred generated
   nodes sharing the aspect clause's span would collide in every `*Sites` map),
   so the transitional rule is:
   - `Lyric.Expand.SpanAllocator` hands out unique spans in an *expansion range*
     of the package's offset space (beyond the highest real offset of the
     package; `spanKey` offsets are already unique across a package's files);
   - `ExpandResult.origins: Map[String, Span]` maps each allocated span key to
     the span of the causing declaration (the aspect clause / aspect use /
     `@derive` annotation);
   - the diagnostic sink (`DiagUtil.diagLocate`) rewrites any diagnostic whose
     span key is in `origins` to the cause span and adds the note "in code
     generated for this declaration";
   - when the checker's tables are NodeId-keyed the allocator is replaced by
     `origin` span reuse and the table is dropped. `synSpan()`, derives' `sp()`
     and the weaver's `noSourceSpan()` uses are deleted in the slice that moves
     each pass, not left behind.

5. **Diagnostics.** Errors in generated code are reported at the causing
   declaration (decision 4). Weaver diagnostics (A0042-A0047) move with the
   weaver and are reported by the expansion step itself; they stay fatal.
   Checks that now see generated code (type errors, mode checks V000x,
   unused/shadow warnings) can reject programs the old order accepted, so each
   slice follows docs/70 §12.2: first make every source the new checks reject
   acceptable in a form the seed also accepts (a census across the compiler,
   stdlib, ecosystem libraries, examples and book snippets, listing the
   generated code each library produces), then switch the check on. Warnings in
   generated code are suppressed (the user cannot fix them); only errors
   surface.

6. **Cross-package aspects and B'-mode.** Template collection
   (`collectAspectTemplates`) and `resolveFromInstances` are unchanged and run
   inside the expansion step; B'-mode specialisation is still a shape cache
   keyed by the use site's resolved parameter types, which are now read from
   signatures as written plus the `TypeOwnerIndex` (the checker is not
   available yet). Where a shape cannot be decided without a checked type
   (an `inferred` argument), the weaver reports A0048 at the use site instead
   of guessing; the census decides whether any library hits it before it is
   switched on.

7. **Slices.** Each is one PR and one decision entry (D371 onward):
   - **S1 derives**: allocator + origins + diagnostic relocation; move
     `deriveFileWithImports` ahead of the check; derive output is checked.
   - **S2 weaver wrappers**: move non-generic and generic function weaving;
     delete `synSpan()` for the wrapper and target; `specialiseWovenContracts`
     removed once mono sees the wrapper.
   - **S3 templates**: `from`-instance, C-mode splices and B'-mode specialised
     bodies checked in the receiving package; weaver callee sites exist, so
     2d's fallbacks (`__aspect_target`, `__lyric_bmode_*`) are deleted (coordinate
     with the 2d session).
   - **S4 cleanup**: the span allocator replaced by cause spans once NodeId
     tables land; docs/book/progress.

## Consequences

- Nothing changes for users in this entry. S1 is the first behaviour change:
  derive output is type-checked, and errors in it surface at the `@derive`.
- Generated code that a backend accepted but the checker rejects becomes a
  compile error in the library that produces it. The census in S1/S2 finds
  these before the check is switched on; the fix is in the generator.
- The expansion step is the one place that knows which nodes are generated, so
  `lyric build --verify-ir` and the TIR builder can report I0002/I0003 against
  the causing declaration.
- Risk: the checker's span-keyed rewrites (`pipeDesugarChecked`, covariant and
  distinct-op lowering) now apply to generated code. That is intended (the
  generated code gets the same lowerings) but is the main regression surface;
  S1 and S2 each run the whole self-test and ecosystem set on both targets.
