# lyric-aws-secrets

AWS Secrets Manager and Parameter Store integration for [Lyric](https://github.com/nichobbs/lyric-lang). Fetches secrets at application startup and injects them into config blocks, with TTL-based caching and local development support.

> **Status**: Library source is complete. Production-ready for `.NET` and JVM targets.

## Platform parity

| Feature flag | Backend | Status |
|---|---|---|
| `aws` | AWS SDK for .NET v3 | Available |
| `local` | Local stub (no-op) | Available |
| `jvm` | AWS SDK for Java v2 | Available |

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
  case NotFound
  case AccessDenied
  case InvalidJson
  case DecryptionFailed
  case NetworkError
  case InternalError
}
```

| Error | Meaning | Action |
|---|---|---|
| `NotFound` | Secret or parameter does not exist | Check the name/path |
| `AccessDenied` | Lambda role lacks IAM permission | Grant `secretsmanager:GetSecretValue` or `ssm:GetParameter` |
| `InvalidJson` | Secret is not valid JSON (for field extraction) | Check secret format |
| `DecryptionFailed` | SecureString decryption failed | Verify KMS permissions |
| `NetworkError` | AWS API unreachable | Check network / VPC / NAT |
| `InternalError` | AWS SDK error | Check AWS console for service issues |

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
      secrets_kernel_jvm.l    AwsSecrets.Kernel.Jvm @cfg(feature="jvm")
  tests/
    *_tests.l                 test modules
```

## See also

- `lyric-lambda` — Lambda runtime adapter; use with `AwsSecrets.init()`
- `lyric-aws-xray` — AWS X-Ray active tracing
- `docs/35-lambda-library.md` — complete design specification
- `docs/03-decision-log.md` D063 — design decisions
