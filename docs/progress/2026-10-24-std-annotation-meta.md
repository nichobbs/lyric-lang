# `Std.AnnotationMeta`: runtime reader for `config { }` field annotations (#7180)

Shipped the stdlib half of the custom-annotation metadata capability (#6866,
D-progress-941, API decision D225):

- `lyric-stdlib/std/annotation_meta.l` (`Std.AnnotationMeta`): decoder, queries
  and argument accessors over the `Lyric.AnnotationMeta` documents the compiler
  already embeds.
- `Std.AnnotationMetaHost` kernel with `_kernel/` (loaded-assembly manifest
  resources), `_kernel_jvm/` (class-path jar entries) and `_kernel_native/`
  (reports unsupported; real implementation tracked in #8524).
- `lyric-stdlib/tests/annotation_meta_tests.l` runs on dotnet and JVM against the
  test's own embedded metadata; `annotation_meta_native_tests.l` pins the native
  `Unsupported` behaviour. All three are wired into CI.
- `docs/17-axiom-audit.md` records the new kernel and its two axioms.

Status: `Std.AnnotationMeta` is in the full stdlib bundle (Tier 13 of
`lyric-stdlib/lyric.full.toml`). #7181 (wiring `lyric-aws-secrets`) stays open:
config blocks have no post-initialisation override seam, see D225 item 5.
