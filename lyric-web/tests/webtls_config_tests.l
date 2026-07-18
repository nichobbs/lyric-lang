//! tests/webtls_config_tests.l — `Web.WebTls` config-template env-var override
//! (docs/61 §6.3 decision 2, docs/25 layered precedence).
//!
//! `WebTls` is a `pub config` template (docs/58): a consumer materialises it
//! with `config Local from Web.WebTls { ... }`, and each field is overridable
//! at startup via `LYRIC_CONFIG_<PKG>_<LOCAL>_<FIELD>`, so cert/key/client-CA
//! paths re-point per environment without a rebuild.  This proves the
//! cross-package `config from` materialisation of `WebTls` and its env-var
//! override end to end.
//!
//! Kept in its own file — free of the `Web.serveTls` end-to-end tests'
//! background-`Task.Run` closures — because module-level config-block emission
//! (static fields + env-reading `.cctor`, dotnet-only, #3228) and closure-class
//! synthesis in the same package currently interact badly in the self-hosted
//! MSIL backend (an `MNewobjByName could not resolve .ctor for '__Closure_0'`
//! codegen abort, filed as #6096); separating the two is the clean fix here
//! (the interaction itself is a separate codegen bug, not part of this TLS
//! surface).
//!
//! dotnet-only: module-level config state emits only on `--target dotnet`
//! (#3228); this suite runs via `lyric test --manifest lyric-web/lyric.toml`
//! (default = dotnet).
@test_module
package Web.WebTlsConfigTests

import Std.Core
import Std.Environment as Env
import Web
import Std.Testing

// Materialise `Web.WebTls` under a local name so its fields are env-overridable
// as LYRIC_CONFIG_WEB_WEBTLSCONFIGTESTS_ENVWEBTLS_<FIELD>.  The .cctor reads
// the environment once, on first touch; under `beforefieldinit` the CLR may
// run it as early as entry to any method referencing the type, so — exactly as
// `config_templates_self_test.l` does — the env set and the read live in
// SEPARATE test methods and no earlier method references `EnvWebTls`.
config EnvWebTls from Web.WebTls {
  certPath: String = "./default-cert.pem"
  keyPath: String = "./default-key.pem"
}

test "set the WebTls env override before EnvWebTls is first touched" {
  Env.setVar("LYRIC_CONFIG_WEB_WEBTLSCONFIGTESTS_ENVWEBTLS_CERTPATH", "/from-env/server.pem")
  assertTrue(true, "env override set for the paired read below")
}

test "EnvWebTls reflects the env override and keeps non-overridden defaults" {
  assertEqual(EnvWebTls.certPath, "/from-env/server.pem", "certPath comes from the env var")
  assertEqual(EnvWebTls.keyPath, "./default-key.pem", "non-overridden keyPath keeps the local default")
  assertFalse(EnvWebTls.requireClientCert, "template default preserved")
}
