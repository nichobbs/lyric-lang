# Config-override seam and `AwsSecrets.init()` on `aws` and `jvm` (#7181, #8529)

Shipped D230:

- A `config { }` block's initialiser now reads an override store before the
  environment and the default: `AppDomain.GetData` in the MSIL `.cctor`
  (`Msil.Lowering.emitConfigLookupMsil`) and `System.getProperty` in the JVM
  `<clinit>` (`Jvm.Lowering.lowerConfigBlock`). An empty value is no override.
- `Std.ConfigOverride` (`setConfigOverride`, `clearConfigOverride`,
  `getConfigOverride`, `isSupported`) over the `Std.ConfigOverrideHost` kernel
  (`_kernel/`, `_kernel_jvm/`, `_kernel_native/`; native reports `Unsupported`
  until config blocks lower there, #7435). Keys are limited to `LYRIC_CONFIG_`.
  Unlike `Std.Environment.setVar`, a registered value is not inherited by child
  processes.
- The annotation-metadata document gained `package` and `envVar`
  (`Lyric.AnnotationMetaEmit.configEnvVarName`); `Std.AnnotationMeta.AnnotatedField`
  gained `packageName` and `envVar`, the store key.
- `lyric-aws-secrets`: `initFromAnnotations` on `aws` and `jvm` now works
  (`AwsSecrets.registerAnnotated` / `registerSecrets`): it fetches every
  `@secretsManager` / `@parameterStore` field whose env var is unset and
  registers the value. The "process-level config cache" the docs described never
  existed; docs and headers now describe the override store.
- #8529: annotation examples in `secrets.l`, the aws-secrets README and docs/35
  used `key: "x"` (P0012); now `key = "x"`.

Tests: `lyric-compiler/lyric/config_override_self_test.l` (dotnet and JVM, in
`compiler-self-tests-batch.sh` and `jvm-generics-self-tests-batch.sh`),
`annotation_meta_emit_self_test.l`, `annotation_meta_tests.l`, and the new
registration cases in `lyric-aws-secrets/tests/secrets_tests.l`.

Docs: docs/25 section 6.0, docs/01, book chapters 12 and 21, docs/10-stdlib-plan,
docs/17-axiom-audit, docs/35 section 7.2, aws-secrets README.

Status: native remains open under #7435 (config block lowering plus a store twin).
