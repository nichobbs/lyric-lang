# Ecosystem remediation: withdraw unimplemented lyric-lambda and lyric-aws-secrets surface (D552 item 2)

Each claim was re-verified against current `main` before removal. Reproduced: `Lambda.Dispatch.dispatchHttp` returned `InternalError` for every API Gateway v1/v2/ALB event, `Lambda.Stream` functions and `Lambda.Direct.streamingHandler` panicked, and `Std.AnnotationMeta` reports `Unsupported` on `--target native` (#8524), which `AwsSecrets` surfaced as `SecretsError.NotImplemented`.

lyric-lambda: removed `Lambda.withRouter`, `LambdaRouter`, `LambdaApp.httpRouter`, `Lambda.withStreamingHandler`, `LambdaApp.streamingHandler`, `Lambda.Direct.streamingHandler`, the `Lambda.ApiGw`, `Lambda.Stream` and `Lambda.Kernel.WebBridge` packages, the `web` feature and the `Lyric.Web` dependency, and the tests that asserted the failures. HTTP events are still detected and rejected with a message saying the library has no HTTP entry point. The JVM suite no longer needs Maven-restored Undertow, so its CI step is a plain `self-test.sh` run.

lyric-aws-secrets: removed `SecretsError.NotImplemented`; `registerSecrets` and `registerAnnotated` are `@cfg(not(target = "native"))`. No manifest `[features]`, `[nuget]` or `[maven]` entry became unused (the `aws` and `jvm` kernels are real).

READMEs gained a "Withdrawn surface" section with migration notes; docs/35, docs/57, docs/71, chapter 29, the v1.0 release notes and CLAUDE.md are updated. The `stability` manifest field is untouched.
