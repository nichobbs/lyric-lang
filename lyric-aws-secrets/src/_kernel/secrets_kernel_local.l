//! AwsSecrets.Kernel.Net (local) — no-op secrets backend for local development.
//!
//! Phase 7 of #733: this file is now a pure-Lyric implementation rather
//! than an `extern package` block (which the emitter does not emit IL
//! for; that's the runtime-no-op trap PR #687's gutting exposed).  The
//! local backend doesn't need a host shim — it's literally "skip AWS,
//! rely on env vars", which is trivially expressible in Lyric.  The AWS
//! SDK backend (`secrets_kernel_aws.l`) does need a host shim and is
//! tracked as the Phase 7 follow-up under #783.
//!
//! In local mode (feature = "local"):
//!
//!   initFromAnnotations() — returns Ok(()) unconditionally; the config
//!     block reader checks env vars per-field at first access, so
//!     missing local overrides surface there with a clear error.
//!
//!   fetchSecret / fetchParameter — always return SecretsError.NotFound
//!     so callers can distinguish "no local override" from "AWS fetch
//!     failed".  The local backend deliberately refuses to fall back to
//!     empty strings — forcing the developer to set the env var
//!     explicitly.
//!
//! Local development workflow:
//!   Set LYRIC_CONFIG_<PACKAGE>_<FIELD> env vars for any @secretsManager /
//!   @parameterStore annotated fields you need during local development.
//!   AwsSecrets.init() will skip the AWS fetch for fields that have env vars
//!   set, so no AWS credentials are required.
//!
//!   For fields without local env vars, init() succeeds but the config
//!   field will be missing when first read.
//!
//! Enabled only when the "local" feature flag is active.
@cfg(feature = "local")
package AwsSecrets.Kernel.Net

import Std.Core
import AwsSecrets

/// Scan annotations; skip AWS fetches; respect env var overrides.
/// Always succeeds — the per-field env var check happens later when
/// the config-block reader resolves the field, which surfaces missing
/// overrides as clear per-field errors rather than a single batch
/// failure here.
@stable(since = "0.1")
pub func initFromAnnotations(ttlSeconds: in Int): Result[Unit, AwsSecrets.SecretsError]
  requires: ttlSeconds >= 0
{
  return Ok(value = ())
}

/// Always returns SecretsError.NotFound — no AWS SDK in local mode.
/// Set the corresponding env var instead.
@stable(since = "0.1")
pub func fetchSecret(
  name: in String, key: in Option[String], ttlSeconds: in Int
): Result[String, AwsSecrets.SecretsError]
  requires: name.length > 0
  requires: ttlSeconds >= 0
{
  return Err(error = NotFound(name = name))
}

/// Always returns SecretsError.NotFound — no AWS SDK in local mode.
/// Set the corresponding env var instead.
@stable(since = "0.1")
pub func fetchParameter(path: in String, decrypt: in Bool, ttlSeconds: in Int): Result[String, AwsSecrets.SecretsError]
  requires: path.length > 0
  requires: ttlSeconds >= 0
{
  return Err(error = NotFound(name = path))
}
