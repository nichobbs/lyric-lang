# lyric-aws-secrets

AWS Secrets Manager and Parameter Store integration for [Lyric](https://github.com/nichobbs/lyric-lang). Fetches secrets at application startup and injects them into config blocks, with TTL-based caching and local development support.

> **Status**: `local`, `jvm`, and `aws` are all production-ready for
> `getSecret`/`getSecretField`/`getParameter`/`getParameterRaw`.
> `initFromAnnotations()` (the config-block annotation scanning path) is
> **NOT_IMPLEMENTED** on every feature except `local` — see below.

## Platform parity

| Feature flag | Backend | Status |
|---|---|---|
| `aws` | AWS SDK for .NET v3 | Available — real `AmazonSecretsManagerClient`/`AmazonSimpleSystemsManagementClient` calls (`initFromAnnotations` config-block path is NOT_IMPLEMENTED, see below) |
| `local` | Local stub (no-op) | Available — no AWS SDK calls; env var overrides only |
| `jvm` | AWS SDK for Java v2 | Available — real `SecretsManagerClient`/`SsmClient` calls (`initFromAnnotations` config-block path is also NOT_IMPLEMENTED, see below) |

`initFromAnnotations()` (the `@secretsManager`/`@parameterStore` config-block
scanning `AwsSecrets.init()` calls) is **NOT_IMPLEMENTED on every feature
except `local`**: the compiler has no capability to read custom annotations
off a compiled config-block field at runtime (tracked in issue #6866).
`getSecret`/`getSecretField`/`getParameter`/`getParameterRaw`
are unaffected by this and work normally on both `jvm` and `aws`.

The `aws` (.NET) feature's `GetSecretValueAsync`/`GetParameterAsync` calls
return `Task<T>`, but binding them did not require making `AwsSecrets`'s
public API `async` (issue #6864): the self-hosted MSIL emitter already
supports `await` inside a plain (non-`async`) function, lowering it to a
blocking `GetAwaiter().GetResult()` shim — the same mechanism
`Std.HttpHost`'s `HttpClient.SendAsync` binding uses. `AwsSecrets`'s
public surface stays exactly as synchronous as `local`/`jvm`'s.

## Packages

| Package | Description |
|---|---|
| `AwsSecrets` | Core: annotations, `init()`, explicit fetch API |
| `AwsSecrets.Kernel.Net` | Extern boundary (one per feature) |

## Installation

```toml
[dependencies]
"Lyric.AwsSecrets" = { path = "../lyric-aws-secrets" }
```

## Quick start

### Config-block annotation model

Apply `@secretsManager` or `@parameterStore` to `@sensitive` config fields:

```lyric
import AwsSecrets

config Database {
  host: String = "localhost"
  port: Int    = 5432
  
  @sensitive
  @secretsManager("my-service/prod", key: "dbPassword")
  password: String
}

config Auth {
  @sensitive
  @secretsManager("my-service/prod", key: "jwtSecret")
  jwtSecret: String

  @sensitive
  @parameterStore("/my-service/signing-key")
  signingKey: String
}
```

### Startup initialization

Call `AwsSecrets.init()` once at process startup, before accessing config:

```lyric
import AwsSecrets
import Lambda
import Web

func main(): Int {
  match AwsSecrets.init() {
    Ok(_) -> {
      // Secrets are now available in config blocks
      var router = Web.create()
      router = Web.addGet(router, "/health", "MyApp.getHealth")
      Lambda.serve(Lambda.newApp() |> Lambda.withRouter(router))
    }
    Err(err) -> {
      Std.Core.log("ERROR", AwsSecrets.errorMessage(err))
      return 1
    }
  }
  return 0
}
```

## Annotations

### `@secretsManager(name)`

Fetch an entire secret value as a plain string:

```lyric
@secretsManager("my-service/api-key")
apiKey: String
```

Fetches the secret named `"my-service/api-key"` and stores it in `apiKey`.

### `@secretsManager(name, key: "field")`

Extract a JSON field from a structured secret:

```lyric
@secretsManager("my-service/prod", key: "dbPassword")
password: String
```

Fetches the secret `"my-service/prod"`, parses it as JSON, extracts the field `"dbPassword"`, and stores it.

### `@parameterStore("/path")`

Fetch a Parameter Store String or SecureString:

```lyric
@parameterStore("/my-service/signing-key")
signingKey: String
```

Fetches the parameter at `/my-service/signing-key`. SecureString parameters are automatically decrypted by the AWS SDK.

## Caching

Fetched values are cached in process memory with a configurable TTL (default 300 seconds = 5 minutes).

On a warm Lambda invocation or repeated requests, the cached value is returned without an AWS SDK call.

### Cache configuration

```bash
export LYRIC_CONFIG_AWSSECRETS_SECRETCACHE_TTLSECONDS=300  # default
```

| Config field | Type | Default | Description |
|---|---|---|---|
| `ttlSeconds` | `Int` | `300` | Cache time-to-live in seconds; `0` = disable caching |

### Cache rotation strategy

For secrets that rotate, choose `ttlSeconds < rotationPeriodSeconds / 6`:

```
If rotation period = 30 days (2,592,000 seconds):
  ttlSeconds should be < 432,000 seconds (5 days)
  Recommended: ttlSeconds = 300 (5 minutes) — safe margin
```

This ensures stale values are refreshed well before the rotation window closes.

## Environment variable override

If the corresponding `LYRIC_CONFIG_<PACKAGE>_<FIELD>` env var is set, `init()` skips the AWS fetch and uses the env var value instead.

This enables **local development without AWS credentials**:

```bash
# Local development — no AWS SDK calls
export LYRIC_CONFIG_DATABASE_PASSWORD="local-password"
export LYRIC_CONFIG_AUTH_JWTSECRET="local-secret"
./my-service
```

Missing env vars that don't have annotations produce a config error at startup, which surfaces incomplete local setups explicitly.

## Explicit fetch API

For one-off secret retrievals outside config blocks:

### `getSecret(name)`

Fetch an entire secret value:

```lyric
import AwsSecrets

match AwsSecrets.getSecret("my-service/api-key") {
  case Ok(value)     -> // use value
  case Err(SecretsError.NotFound) -> // secret not found
  case Err(SecretsError.AccessDenied) -> // IAM permission denied
  case Err(err)      -> // other error
}
```

### `getSecretField(name, field)`

Extract a JSON field from a structured secret:

```lyric
import AwsSecrets

match AwsSecrets.getSecretField("my-service/prod", "apiKey") {
  case Ok(value)     -> // use value
  case Err(err)      -> // error
}
```

### `getParameter(path)`

Fetch a Parameter Store value:

```lyric
import AwsSecrets

match AwsSecrets.getParameter("/my-service/signing-key") {
  case Ok(value)     -> // use value
  case Err(err)      -> // error
}
```

## Error handling

### `SecretsError`

```lyric
union SecretsError {
  case NotFound(name: String)
  case AccessDenied(name: String, message: String)
  case DecryptionError(name: String, message: String)
  case ParseError(name: String, key: String, message: String)
  case NetworkError(name: String, message: String)
  case BinaryValueUnsupported(name: String)
  case NotImplemented(feature: String, message: String)
  case InvalidConfig(field: String, message: String)
}
```

| Error | Meaning | Action |
|---|---|---|
| `NotFound` | Secret or parameter does not exist, or is not accessible with the current IAM role | Check the name/path |
| `AccessDenied` | IAM role lacks permission | Grant `secretsmanager:GetSecretValue` or `ssm:GetParameter` |
| `DecryptionError` | KMS decryption of a SecureString/secret failed | Verify KMS permissions |
| `ParseError` | Secret is JSON but the requested key is absent or the value is not valid JSON | Check the secret's JSON shape and key name |
| `NetworkError` | A transient network/service error, or (on `jvm`/`aws`) any AWS error the best-effort message classifier didn't recognise | Retry, or read `errorMessage` for detail |
| `NotImplemented` | (`jvm`/`aws`) `init()`'s config-block annotation scan, which has no compiler support yet (#6866). Retrying never helps | Use the explicit `getSecret`/`getParameter` API or env var overrides |
| `InvalidConfig` | `SecretCache.ttlSeconds` (from `LYRIC_CONFIG_AWSSECRETS_SECRETCACHE_TTLSECONDS`) is outside 0..86400. Returned by `init()` and every get call without fetching | Fix the env var |
| `BinaryValueUnsupported` | (`jvm`/`aws`) The secret is stored as raw binary (Secrets Manager's `SecretBinary`) rather than a string (`SecretString`) — this API only supports string-valued secrets | Store the value as a `SecretString` instead, or base64-encode it as one |

On both the `jvm` and `aws` features, classification into `NotFound`/
`AccessDenied`/`DecryptionError` is **best-effort substring matching** on
the AWS SDK's own exception messages — Lyric's `catch Bug` boundary only
exposes a flattened message string, not the exception's real type, so an
unrecognised message always falls back to `NetworkError` rather than
misclassifying. See `secrets_kernel_jvm.l`/`secrets_kernel_aws.l`'s
headers for the full rationale.

### `errorMessage(err)`

Get a human-readable error message:

```lyric
import AwsSecrets

match AwsSecrets.init() {
  case Err(err) -> {
    Std.Core.log("ERROR", AwsSecrets.errorMessage(err))
  }
  case Ok(_)    -> {}
}
```

## Local development (feature = "local")

When built with the `local` feature, `AwsSecrets.init()` is a no-op:

- Scans annotations but skips all AWS SDK calls
- Fields with env var overrides are populated from the environment
- Fields without overrides remain unset, producing a config error on first access

This makes the missing-local-override explicit and catches mistakes during development.

Explicit fetch functions (`getSecret`, `getParameter`) always return `SecretsError.NotFound` in local mode.

## IAM permissions

The Lambda execution role must have the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": [
        "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:my-service/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter"
      ],
      "Resource": [
        "arn:aws:ssm:REGION:ACCOUNT_ID:parameter/my-service/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt"
      ],
      "Resource": [
        "arn:aws:kms:REGION:ACCOUNT_ID:key/*"
      ]
    }
  ]
}
```

## Complete example

```lyric
import AwsSecrets
import Lambda
import Web
import Std.Core

config Database {
  host: String = "localhost"
  port: Int    = 5432
  @sensitive
  @secretsManager("myapp/db", key: "password")
  password: String
}

config Auth {
  @sensitive
  @secretsManager("myapp/auth", key: "jwtSecret")
  jwtSecret: String

  @sensitive
  @parameterStore("/myapp/api-key")
  apiKey: String
}

pub func handleGetUser(userId: in Int): Result[User, Web.ApiError] {
  // Access config values (already populated by AwsSecrets.init)
  val password = Database.password()
  val jwtSecret = Auth.jwtSecret()
  // ... use secrets ...
}

func main(): Int {
  match AwsSecrets.init() {
    Ok(_) -> {
      var router = Web.create()
      router = Web.addGet(router, "/users/{id}", "MyApp.handleGetUser")
      Lambda.serve(Lambda.newApp() |> Lambda.withRouter(router))
    }
    Err(err) -> {
      Std.Core.log("ERROR", AwsSecrets.errorMessage(err))
      return 1
    }
  }
  return 0
}
```

## Package layout

```
lyric-aws-secrets/
  lyric.toml                  package manifest
  README.md                   this file
  src/
    secrets.l                 AwsSecrets  (annotations, init, fetch API)
    _kernel/
      secrets_kernel_aws.l    AwsSecrets.Kernel.Net @cfg(feature="aws")
      secrets_kernel_local.l  AwsSecrets.Kernel.Net @cfg(feature="local")
      secrets_kernel_jvm.l    AwsSecrets.Kernel.Net @cfg(feature="jvm")
  tests/
    *_tests.l                 test modules
```

## See also

- `lyric-lambda` — Lambda runtime adapter; use with `AwsSecrets.init()`
- `lyric-aws-xray` — AWS X-Ray active tracing
- `docs/35-lambda-library.md` — complete design specification
- `docs/03-decision-log.md` D063 — design decisions
