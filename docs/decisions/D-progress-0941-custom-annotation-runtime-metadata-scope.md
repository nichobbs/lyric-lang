# D-progress-941 — Scope and design for custom-annotation runtime metadata (#6866)

**Status:** accepted

**Context.** #6866 reports that the compiler has no facility for reading a
user-defined annotation's name/arguments back off a compiled declaration at
runtime, on either backend. This blocks the `@secretsManager`/
`@parameterStore`-style `config { }` field annotations `docs/35-lambda-library.md`
specs for `lyric-aws-secrets`: `AwsSecrets.init()` calls
`SecretsKernel.initFromAnnotations`, which is `NOT_IMPLEMENTED` on the `aws`
and `jvm` kernels today (`lyric-aws-secrets/src/secrets_kernel_aws.l`,
`secrets_kernel_jvm.l:257-266`) for exactly this reason.

Three existing metadata-adjacent facilities were audited and each is close
but insufficient:

- **`Lyric.ContractMeta` / `Lyric.ContractMetaEmit`** (docs/45, D098,
  D-progress-471) — a pure-byte PE/JAR resource reader+emitter, but scoped to
  function contracts (`requires`/`ensures`) and public-API shape. It never
  captures annotation name/args, and never touches `config { }` declarations.
  It also lives under `lyric-compiler/`, depends on the self-hosted
  lexer/parser/CLI shell, and is too heavy to link into a deployed Lambda
  binary.
- **JVM `@LyricTest`** (`lyric-compiler/jvm/classfile.l`, docs/32,
  D-progress-206) — a real, working precedent for emitting
  `RuntimeVisibleAnnotations` (JVMS §4.7.16) and reading them back via
  `Class.forName` reflection, but it is one hardcoded compiler-synthesized
  annotation shape, not a general "any user `@foo(...)`" mechanism, and it
  pulls in JVM reflection — a runtime capability this project has otherwise
  deliberately avoided (see docs/40 §7's AOT-safety stance, which
  `Lyric.ContractMeta`'s pure-byte-parsing approach exists to satisfy on the
  MSIL side).
- **MSIL `CustomAttribute` table (0x0C)** — fully modeled in
  `lyric-compiler/msil/tables.l` (`addCustomAttr`, full row serialization),
  but has zero callers anywhere in the codebase. Schema-complete, dead code.

`Lyric.Annotation`/`AnnotationArg`/`AnnotationValue` (`parser_ast.l:44-59`)
already carry every user annotation — including on `ConfigField`
(`parser_ast.l:832-842`) — through the front end. Nothing downstream
preserves that past parsing today; `@sensitive` and friends are pure
documentation convention, not compiler-enforced.

**Decision.** Build a new, narrow, **runtime-safe sibling of contract-meta**
— not a generalization of `Lyric.ContractMeta` (too heavy for a deployed
binary to link), and not real .NET/JVM reflection (the JVM `@LyricTest`
precedent's approach, rejected here for the same AOT-safety reason
`Lyric.ContractMeta` was built to satisfy on MSIL, and for parity — MSIL has
no equivalent low-ceremony reflection story). Concretely:

1. **Compile-time emission** (new package, e.g.
   `lyric-compiler/lyric/annotation_meta_emit.l`, mirroring
   `contract_meta_emit.l`'s two-pass hashing structure): walk each compiled
   package's `IConfig` declarations, collect
   `(configName, fieldName, annotationName, args)` tuples, and embed them as
   a small new resource — `Lyric.AnnotationMeta` (MSIL, via
   `addManifestResource`, mirroring `embedLyricContract`) /
   `Lyric.AnnotationMeta.<Pkg>` (JVM JAR entry, mirroring
   `Lyric.Contract.<Pkg>`) — alongside the existing `Lyric.Contract`
   resource in both `Msil.Bridge` and `Jvm.Bridge`.
2. **Runtime reader** (new stdlib package, e.g.
   `lyric-stdlib/std/annotation_meta.l` + a `_kernel`/`_kernel_jvm` pair):
   locate the currently-executing assembly's own file (the one genuinely new
   FFI surface this needs — `Assembly.Location` /
   `ProtectionDomain.getCodeSource()`, a narrow "where am I" extern, not
   general reflection), reuse a resource-locator factored out of
   `Msil.MetadataReader`/`Jvm.ZipReader` (stdlib-linkable, without dragging
   in `Lyric.Lexer`/`Lyric.Parser`), and JSON-decode via the existing
   `Std.Json`. Public entry point:
   `Std.AnnotationMeta.fieldsWithAnnotation(annotationName): List[AnnotatedField]`.
3. **Consumer wiring**: `lyric-aws-secrets`'s
   `AwsSecrets.Kernel.Net/Jvm.initFromAnnotations` calls the new stdlib API
   instead of returning `NOT_IMPLEMENTED`, closing out the docs/35 §7.2
   caveat and the ecosystem README platform-parity table entry.

**Why not the alternatives.** Generalizing `Lyric.ContractMeta` in place
would make every consumer of annotation metadata pull in the self-hosted
lexer/parser/CLI-shell dependency chain — acceptable for `lyric doc`/
`public-api-diff` tooling, not for a Lambda cold-start binary. Real
reflection (`Class.forName` on JVM, no comparably simple MSIL analog) is
asymmetric across targets and reintroduces the exact runtime-discovery
surface `Lyric.ContractMeta`'s byte-parsing approach was built to avoid.
Extending `@generate` (docs/40, D075) doesn't fit either: `@generate` is
scoped to `exposed record`/`record`/`union`/`interface` items that get
*synthesized code*, not `config` blocks needing metadata *read back*, and is
itself only speced, not implemented (`Generate.synthesizeItems` has no
callers yet).

**Scope split — three PRs, not one.** Per this repo's CLAUDE.md standard
("prefer landing less scope at production quality over more scope at
bootstrap quality... split the work and ship the slice you can finish
properly"), each of the three pieces above is independently substantial (a
new metadata schema + emitter + two-backend resource embedding; a genuinely
new runtime capability with a new FFI extern surface; then consumer wiring +
verification against real config-block scenarios on both targets) and each
is fully finished and self-tested on its own:

- PR 1 — compile-time `Lyric.AnnotationMeta` emission (both MSIL + JVM
  resource embedding) + self-tests. Tracked in #6866 directly (this PR).
- PR 2 — `Std.AnnotationMeta` runtime reader (own-assembly-path extern +
  slim resource reader + JSON decode), both targets. Tracked in a follow-up
  issue linked from #6866.
- PR 3 — wire `lyric-aws-secrets`'s `initFromAnnotations` on `aws`/`jvm` to
  the new API; close #6866 and update docs/35 §7.2 + the ecosystem README
  platform-parity table. Tracked in a follow-up issue linked from #6866.

Landing all three in one PR would ship an untestable-in-isolation blob
against this repo's own "smaller, fully-finished slice" standard; #6866
stays open until PR 3 lands.

**Open questions carried into PR 1/2:**

- Exact resource-locator dedup: how much of `Msil.MetadataReader`/
  `Jvm.ZipReader`'s PE/JAR resource lookup should be factored into a shared,
  stdlib-linkable helper vs. duplicated narrowly for
  `Lyric.AnnotationMeta` alone (a straight duplication is lower-risk for PR 1
  but adds long-term maintenance surface — left to PR 2, which is the first
  consumer that actually needs a stdlib-linkable reader).
- Whether `Lyric.AnnotationMeta`'s JSON schema should be versioned/hashed
  like contract metadata v3 (D098) from day one, or start unversioned and
  gain a format version only when a second consumer needs one. PR 1 follows
  the v3 two-pass-hash precedent by default; revisit if it proves premature.

**Related:** #6866 (this decision), docs/35-lambda-library.md (motivating
use case), docs/40-source-generators.md (`@generate`, the mechanism this is
deliberately NOT built on), docs/45-contract-metadata-direct-resolution.md
/ D098 (the v3 two-pass-hash precedent this mirrors), D-progress-471
(`Lyric.ContractMetaEmit` shipping), docs/32-junit-runner-sketch.md /
D-progress-206 (`@LyricTest` — the JVM-reflection precedent this
deliberately does not generalize).
