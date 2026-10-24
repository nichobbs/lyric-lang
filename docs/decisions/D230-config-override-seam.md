# D230 - A config-override seam for `config { }` blocks, and `initFromAnnotations` on top of it (#7181)

**Status:** shipped (dotnet and JVM; native reports `Unsupported`, tracked in #7435)

Completes D225 item 5. `lyric-aws-secrets` documented that `AwsSecrets.init()`
fills "the process-level config cache" that `config { }` blocks then read. No
such cache existed: a block compiles to a static holder initialised once, on
first access, from `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>` (MSIL `.cctor`, JVM
`<clinit>`), and a required field with no value exits 78 right there. A value
fetched at startup had nowhere to go except the process environment.

## What already worked, and why it is not enough

`Std.Environment.setVar` does reach a config initialiser on both targets: it
sets the real environment block on .NET, and on the JVM an overlay
(`Std.EnvironmentHost.envOverlay`) that `<clinit>` checks first (#7594). Using it
for a secret has two defects:

- **It leaks.** The value is inherited by every child process spawned later
  (`Std.Process` copies the JVM overlay onto the child as well), and shows up in
  anything that dumps the environment.
- **It is an accident, not an interface.** Nothing says a secret may be
  registered there, in what order, or what wins over what.

## Decision

1. **An override store, consulted before everything else.** A config
   initialiser reads, per field, in this order: the override store,
   `Std.Environment.setVar`/the real environment, the declared default (or the
   exit-78 abort for a required field). The store is keyed by the same
   `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>` string, so a field has one name
   everywhere.
2. **The store is a BCL/JDK primitive, so a compiled package needs no stdlib
   reference.** The initialiser is emitted into the user's package; making it
   call a Lyric helper would add an assembly/class dependency to every package
   that declares a config block. Instead:
   - .NET: `AppDomain.CurrentDomain.GetData(name)` (`isinst string`), written by
     `AppDomain.SetData`. `Msil.Lowering.emitConfigLookupMsil` emits the read
     for every place the old code called `Environment.GetEnvironmentVariable`.
   - JVM: `System.getProperty(name)` ahead of the overlay and `System.getenv`
     in `Jvm.Lowering.lowerConfigBlock`; written by `System.setProperty`.

   Neither table is the environment block, so a registered value is not
   inherited by children and not listed by environment dumps. A JVM program may
   also pass `-DLYRIC_CONFIG_...=v`; that is a consequence, not a feature.
3. **An empty value is no override.** This matches the existing rule that an
   empty environment value means "absent" (#6204), makes the two stores
   behave alike, and gives a clearing operation without needing a null
   (`SetData` cannot be handed one from Lyric).
4. **`Std.ConfigOverride` is the only writer.** `setConfigOverride`,
   `clearConfigOverride`, `getConfigOverride`, `isSupported`. Keys must start
   with `LYRIC_CONFIG_`, because on the JVM the store is the system-property
   table and an unchecked key would write arbitrary properties
   (`java.class.path`). Values containing NUL are refused, as no environment
   variable can hold one. Errors: `Unsupported`, `InvalidKey`, `InvalidValue`.
5. **Ordering is the caller's job and is documented, not hidden.** A block
   reads the store when it is first accessed and never again, so a value
   registered afterwards is not seen. The alternative (make every field read
   check the store) would turn a static `ldsfld`/`getstatic` into a call and
   break the "initialised once, immutable" guarantee of docs/25. A test pins the
   once-only behaviour.
6. **The compiler records the key.** The annotation-metadata document gains
   `package` and `envVar` members (`Lyric.AnnotationMetaEmit.configEnvVarName`;
   `Std.AnnotationMeta.AnnotatedField` gains `packageName` and `envVar`), so a
   consumer registers under `field.envVar` instead of re-deriving the naming rule
   and the package, which the document did not carry before. The format stays
   unversioned and the decoder requires both members: both ends ship in the same
   release and no older document exists outside this repository.
7. **`initFromAnnotations` on `aws` and `jvm`.** `AwsSecrets.registerAnnotated`
   reads `Std.AnnotationMeta.allAnnotatedFields()`, keeps `@secretsManager` and
   `@parameterStore` fields, skips a field whose environment variable is already
   set (local development needs no AWS credentials), fetches through the
   kernel's `fetchSecret`/`fetchParameter`, and registers the value. The engine
   is `AwsSecrets.registerSecrets(fields, fetchSecret, fetchParameter)` so it is
   testable without AWS. An annotation without its name/path argument, a field
   carrying both annotations, and an empty fetched value are typed errors. The
   `local` kernel stays a no-op. `init()` must run before the first read of an
   annotated block.
8. **Native.** The native backend rejects `config { }` blocks (`N0025`, #7435),
   so there is no initialiser to consult a store. `Std.ConfigOverride` reports
   `Unsupported` there rather than accepting a registration nothing reads; the
   native lowering and a real store twin are part of #7435.

## Doc fix (#8529)

Annotation examples in `secrets.l`, the aws-secrets README and docs/35 wrote
`key: "x"`, which is `P0012`; the accepted form is `key = "x"`.

## Consequences

- A startup-fetched secret reaches a `config { }` block without entering the
  process environment.
- The MSIL `.cctor` of a config block grows by a few instructions per read of
  a field; the read happens once per process.
- Pinned on both targets by `lyric-compiler/lyric/config_override_self_test.l`;
  the metadata members by `annotation_meta_emit_self_test.l` and
  `lyric-stdlib/tests/annotation_meta_tests.l`; the secrets engine by
  `lyric-aws-secrets/tests/secrets_tests.l`.
