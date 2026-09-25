# D-progress-964 — T0128 case patterns must match the scrutinee's type; JVM imported-union case construction; lyric-validation, lyric-aws-secrets and lyric-lambda contracts

**Status:** shipped

## T0128: a case pattern must belong to the scrutinee's type

The type checker accepted a union-case pattern against a scrutinee of any
type. `case Some(i)` against an `Int` type-checked. On MSIL it then treated
the `Int` as the case object and took the `Some` arm; on the JVM it failed
verification. A case of one union matched against another union
(`case Ok(v)` on an `Option`) was accepted the same way.

`unionCaseSymbolForScrutinee` falls back to a name-based lookup when the
scrutinee's own type has no such case. `bindPatternTyped` now checks the
resolved case against the scrutinee and reports **T0128** when:

- the scrutinee is a primitive, tuple, function, array or slice; or
- the scrutinee is a union other than the one declaring the case.

A bare nullary case (`case None`, parsed as a binding) is checked the same
way against every case of that name. Scrutinees whose type is unknown or
open (`TyError`, type variables, `Self`, nullable, exception) are not
checked. Enum scrutinees are only checked against union cases, since there
is no enum-declaration index to confirm ownership.

The stdlib, all ecosystem suites and the compiler's own sources compile
unchanged. The only real hit was `lyric-validation`'s new `isHttpUrl`,
which matched `indexOf` results as `Option` in a file that did not import
`Std.String`, so `indexOf` returned the raw `Int` sentinel.

Host `String` methods other than `indexOf`/`lastIndexOf` still type as
`TyError`, which hides T0128 (and every other check) downstream of calls
like `s.substring(...)`. That gap is tracked in #7335.

Coverage: four `typechecker_self_test.l` cases (primitive scrutinee with a
constructor and a bare nullary pattern, a foreign union's case, and an
own-case negative).

## JVM: imported-union-qualified case construction

`Lambda.LambdaError.TimeoutError(remainingMs = ms)`, written in a library
aspect and woven into a consumer, failed JVM codegen with
`J008 class 'Lambda.LambdaError' not found in JDK jmods`. The
imported-type seed (docs/44 m-58) puts imported type names into
`externTypes`, so `lowerMethodCall` sent the call to the auto-FFI static
path. It now checks for a registered `<Type>$<member>` case constructor
first. A real extern type never registers one. This affected
`Lambda.Aspects.DeadlineGuard` for every JVM consumer.
`imported_union_case_ctor_self_test.l` covers the package-qualified and
simple-name spellings on both targets.

## lyric-validation (#7253)

- `matches` requires a non-empty pattern and compiles it with
  `Std.Regex.tryCompile`, so an invalid pattern is a validation error
  rather than an exception. The new
  `matchesRegex(value, field, regex, description)` takes a pre-compiled
  `CompiledRegex` (built with a timeout) and treats a timeout as a failure.
- `url` delegates to the new `isHttpUrl`. It parses the authority and
  rejects:
  - control characters and spaces;
  - userinfo (`https://@evil`);
  - an empty host or a host beginning with `.` or `-`;
  - bad ports.

  It previously accepted any string with an `http(s)://` prefix.
- The `ValidateInput` aspect panics before the handler when
  `minLen < 0 or maxLen < minLen`, instead of rejecting every request or
  failing a precondition per call.

## lyric-aws-secrets (#7253)

- `SecretCache.ttlSeconds` comes from an env var. `init()` and every get
  call now return `InvalidConfig` when it is outside 0..86400
  (`checkCacheTtl`, `isValidCacheTtl`, `maxCacheTtlSeconds`). Previously
  a negative value failed a kernel precondition, and a huge value meant
  rotated secrets were never refreshed.
- `initFromAnnotations` on the `aws` and `jvm` kernels returns the new
  `NotImplemented(feature, message)` case instead of `NetworkError`, which
  told callers a retry might succeed (#6866 is the underlying gap).
- `SecretsError` gains `NotImplemented` and `InvalidConfig`. This is
  additive, but exhaustive matches over `SecretsError` need the two new
  arms.
- The local kernel's `initFromAnnotations` still cannot verify that
  overrides exist. There is no way to enumerate annotated fields until
  #6866 lands.

## lyric-lambda (#7253)

- The new `denyAnonymous(methodArn)` denies a caller with no verified
  identity under the fixed principal `anonymousPrincipalId()`. `allow`
  and `deny` document that a missing principal claim must be answered with
  it, since their `principalId` precondition would turn a bad token into
  a 500.
- `DeadlineGuard` drops its meaningless `requires: args.ctx != null` and
  panics before the handler when `thresholdMs < 0`. The new
  `tests/lambda_aspect_weaving_tests.l` covers proceed, short-circuit and
  misconfiguration. It needed the qualified `Lambda.LambdaContext`
  spelling because of an A0047 false positive (#7336).
- `Lambda.Stream.write`/`writeBytes` treat an empty chunk as a no-op.
  `setContentType` requires no CR/LF.
- `runLocalServer` requires a port in 1..65535.
- The lyric-lambda suite does not compile on the JVM for unrelated reasons
  (#7337). Its new weaving test cannot build there either: lyric-web's
  Undertow Maven artifacts are not propagated into a dependent project's
  JVM build, which is the same issue.
