# D223 - `Std.AnnotationMeta`: the runtime reader for `config { }` field annotations (#7180)

**Status:** shipped (dotnet and JVM; native tracked in #8524)

Delivers PR 2 of the split D-progress-941 set out for #6866, and fixes the open
questions it carried into PR 2. The compile-time half (`Lyric.AnnotationMetaEmit`)
already embeds a `Lyric.AnnotationMeta[.<Pkg>]` document per package.

## Decision

1. **API shape.** `Std.AnnotationMeta` (`lyric-stdlib/std/annotation_meta.l`):
   - `allAnnotatedFields(): Result[List[AnnotatedField], AnnotationMetaError]`
   - `fieldsWithAnnotation(annotationName): Result[List[AnnotatedField], AnnotationMetaError]`
     (leading `@` accepted)
   - `parseAnnotationMeta(json)`, the pure decoder, exposed for tests
   - `namedArg(field, name)` / `positionalArg(field, index)` accessors
   - `AnnotatedField { configName, fieldName, annotationName, args }`,
     `AnnotationArg { name, kind, value }` (strings as written, tagged by kind;
     nothing is evaluated)
   - `AnnotationMetaError = Unsupported(reason) | Malformed(message)`.

   D-progress-941 sketched `fieldsWithAnnotation(name): List[AnnotatedField]`. It
   returns a `Result` instead because two situations must not look like "no such
   annotation": a target that embeds no metadata (native) and a corrupt document.
   An unused annotation is still `Ok([])`.
2. **Kernel seam: resource enumeration, not byte parsing, not type reflection.**
   The kernel (`Std.AnnotationMetaHost`) exposes only
   `hostAnnotationMetaSupported(): Bool` and
   `hostAnnotationMetaDocuments(): slice[String]`. On .NET it reads the manifest
   resource tables of every loaded non-dynamic assembly
   (`AppDomain.GetAssemblies`, `Assembly.GetManifestResourceNames/Stream`); on
   the JVM it walks the `.jar` entries on `java.class.path` with a
   `ZipInputStream`. This replaces D-progress-941's "own-assembly path +
   hand-rolled resource locator": the managed-resource APIs do not inspect types,
   members or attributes (the AOT concern that ruled out reflection), and they
   avoid a second PE/ZIP parser in the stdlib. Scanning every loaded assembly
   (rather than only the entry assembly) means a library's `config` blocks are
   found when an application links it. JSON decoding is `Std.JsonValue`, which
   works on both targets (`Std.Json` is .NET-only).
3. **Metadata stays unversioned and unhashed**, as emitted today. No second
   consumer needs tamper detection; add a format version with the first schema
   change.
4. **Native:** the native backend embeds no metadata, so its kernel twin reports
   `false` and every query returns `Unsupported`. Emission and a real twin are
   tracked in #8524.
5. **Consumer wiring (#7181) is not part of this change.** Investigation showed
   the premise of PR 3 does not hold yet: a `config { }` block compiles to a
   static holder initialised once from `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>`
   at first access (MSIL `.cctor`, JVM `<clinit>`; a required field with no value
   aborts with exit 78 there). There is no "process-level config cache" that
   `AwsSecrets.init()` could populate afterwards. Delivering `@secretsManager` /
   `@parameterStore` needs a compiler-level override seam consulted by that
   initialiser on both backends; that is its own decision. #7181 stays open with
   that finding.

## Consequences

- A library can discover its own annotations on `config` fields without
  reflection, on dotnet and JVM.
- The JVM scan reads each class-path jar sequentially; the cost is linear in the
  compressed size of the jars on the class path, paid on each call.
