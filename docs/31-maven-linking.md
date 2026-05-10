# 31 — Maven Central Linking

**Status:** Drafted. 2026-05-08.
**Implementation:** Phase 6 (JVM backend; see `docs/18-jvm-emission.md`).
**Decision-log entry:** D053.

## 1. Motivation

The JVM emission strategy (`docs/18-jvm-emission.md`) specifies how Lyric
source compiles to Java bytecode, but the specification left open how a
JVM-targeted Lyric project consumes existing Java libraries from Maven
Central.

This document specifies the discovery, restore, and reference flow that
makes Maven Central a first-class dependency source for JVM-targeted Lyric
projects, mirroring what `docs/21-nuget-linking.md` delivers for the .NET
target.

The `extern package` path already exists for hand-curated JVM FFI (see
`docs/18-jvm-emission.md` Appendix A). This document adds the automated
tier: given a Maven coordinate, `lyric restore` downloads the JAR and
generates an `@axiom`-annotated extern shim automatically.

## 2. `lyric.toml` extensions

```toml
[maven]
"com.fasterxml.jackson.core:jackson-databind" = "2.17.0"
"org.postgresql:postgresql"                   = "42.7.3"
"org.slf4j:slf4j-api"                         = "2.0.12"

[maven.options]
repositories = ["central"]   # default; custom repos are a Phase 7 follow-up
java_version = "21"           # default: project's jvm_target
```

| Field | Default | Meaning |
|---|---|---|
| `[maven]` | empty | Map of `groupId:artifactId` → version. Each entry is a direct Maven dependency. |
| `repositories` | `["central"]` | Repository list. Stage 1 supports `"central"` (Maven Central) only. |
| `java_version` | project's `jvm_target` | Minimum Java version the restore evaluates against when selecting classifier JARs. |

The `[maven]` table applies only when `target = "jvm"` is set in
`[project]`. It is ignored silently for `.NET`-targeted builds so that a
single `lyric.toml` can carry both `[nuget]` and `[maven]` tables for
future dual-target projects.

## 3. `lyric restore` flow

`lyric restore` already handles Lyric-package binary dependencies. Adding
Maven support extends the same command for JVM targets:

1. **Collect coordinates.** Parse every `groupId:artifactId = "version"`
   entry from `[maven]`.
2. **Invoke the bundled resolver.** The Lyric SDK ships
   `$LYRIC_SDK/lib/lyric-resolver.jar`, a self-contained JAR that embeds
   Apache Maven Resolver 2.x (Apache-2.0 licensed). The CLI runs:

   ```
   java -jar $LYRIC_SDK/lib/lyric-resolver.jar
   ```

   Communication is JSON on stdin / JSON on stdout. The CLI sends a
   resolve request:

   ```json
   {
     "coordinates": [
       { "group": "com.fasterxml.jackson.core",
         "artifact": "jackson-databind", "version": "2.17.0" }
     ],
     "repositories": ["central"],
     "javaVersion": "21",
     "cacheDir": "~/.lyric/maven-cache",
     "outputDir": "target/restore/jars"
   }
   ```

   The resolver responds with the list of resolved JAR paths (direct +
   transitive closure):

   ```json
   {
     "resolved": [
       { "coordinate": "com.fasterxml.jackson.core:jackson-databind:2.17.0",
         "jar": "target/restore/jars/jackson-databind-2.17.0.jar" },
       ...
     ],
     "errors": []
   }
   ```

   `java` must be on `PATH` (which is guaranteed for any JVM-targeted
   build). `mvn` is not required.

3. **Materialise JARs.** The resolver writes resolved JARs into
   `target/restore/jars/` and caches them at
   `$LYRIC_USER_CACHE/maven/<group>/<artifact>/<version>/`.
   `LYRIC_USER_CACHE` defaults to the OS user-home cache directory
   resolved by the runtime's home-directory API (not shell `~` expansion):
   `~/.lyric` on POSIX, `%APPDATA%\lyric` on Windows. The cache is
   write-once; cached JARs are never overwritten, ensuring reproducibility
   across invocations.

4. **Verify checksums.** The resolver verifies each downloaded JAR against
   its Maven Central checksum. SHA-256 (`.sha256`) is used when available
   (artifacts uploaded after ~2019); SHA-1 (`.sha1`) is the fallback for
   older artifacts. Artifacts where neither checksum file is present on
   Maven Central are rejected with `B0050`. MD5 is never accepted.

5. **Generate auto-shims** (§4) — one `_extern/<PascalGroup>_<PascalArtifact>.l`
   per `[maven]` entry — by reflecting on each direct-dependency JAR's
   public surface. Files are written to the source tree so reviewers see
   the surface that will be in scope; the generator is idempotent and
   deterministic (sorted by name, locked to the version).

Only direct `[maven]` dependencies receive auto-shims. Transitive
dependencies are resolved and materialised for the runtime classpath but
do not get shims unless the user declares them explicitly (keeps the
auditable `@axiom` boundary aligned with what the user wrote).

## 4. Auto-generated extern shims

For each `[maven]` entry, the shim generator emits a
`_extern/<PascalGroup>_<PascalArtifact>.l` file. Example for
`org.postgresql:postgresql`:

```
@axiom("from Maven org.postgresql:postgresql v42.7.3")
package OrgPostgresql.Postgresql

extern type Connection        = "java.sql.Connection"
extern type PreparedStatement = "java.sql.PreparedStatement"
extern type ResultSet         = "java.sql.ResultSet"

@externTarget("java.sql.DriverManager.getConnection")
pub func getConnection(url: in String): Result[Connection, JvmException] = ()

@externTarget("java.sql.Connection.prepareStatement")
pub func prepareStatement(
  conn: in Connection,
  sql:  in String,
): Result[PreparedStatement, JvmException] = ()

@externTarget("java.sql.PreparedStatement.executeQuery")
pub func executeQuery(
  stmt: in PreparedStatement,
): Result[ResultSet, JvmException] = ()
```

Important properties:

- **Every generated package carries `@axiom("from Maven <groupId>:<artifactId>
  v<version>")`**. This is the mandatory annotation distinguishing verified
  Lyric code from the unverified host surface. Hand-written `_kernel/*.l`
  files use the same scheme.
- **Checked exceptions map to `Result[T, JvmException]`** (§5). Methods that
  declare only unchecked exceptions (`RuntimeException` / `Error` subclasses)
  in their `throws` clause, or none, return `T` directly.
- **Files are committed to the source tree.** Auto-generation is idempotent
  and deterministic, so check-in shows up in code review when a dependency
  is added or upgraded. The generator embeds a `# lyric:generated-sha256:<hash>`
  comment in the first line of each shim. `lyric restore` re-generates the
  expected content, hashes it, and compares against the stored hash; a
  mismatch emits `B0053`.
- **Skipped members** are listed in `_extern/<PascalGroup>_<PascalArtifact>.skip.md`
  with a short reason. Skipped surface includes: `var`-arg-only overloads,
  `Unsafe`-dependent types, non-public types referenced in public signatures,
  Kotlin-specific bytecode constructs (`suspend` functions, companion objects),
  and anything outside Lyric's type system. Skipped entries are informational
  (`B0052`).
- **Keyword collisions.** Where a Java member name clashes with a Lyric keyword
  (e.g. a method named `match` or `type`), the generator suffixes it with `_`
  and emits a `// renamed: keyword collision` comment.

## 5. Checked exceptions

`JvmException` is an extern type declared in the JVM stdlib kernel
(`stdlib/std/_kernel/jvm_exception.l`):

```
@axiom("JVM runtime boundary")
package Std.Kernel.Jvm

extern type JvmException = "java.lang.Exception"

@externTarget("java.lang.Throwable.getMessage")
pub func message(e: in JvmException): String? = ()

@externTarget("java.lang.Throwable.getCause")
pub func cause(e: in JvmException): JvmException? = ()
```

`JvmException` also exposes `typeName(e) -> String`, which returns the
runtime class name of the exception (e.g. `"java.io.IOException"`).
Its `@externTarget` path chains through `getClass().getName()`, which
is an implementation detail of the kernel; the binding is not
representable in a single `@externTarget` string and is instead
provided via a small Java helper method compiled into the JVM stdlib
kernel JAR.

Shim generator policy:

| Java `throws` clause | Lyric return type |
|---|---|
| Declares one or more checked exceptions | `Result[T, JvmException]` |
| Declares only unchecked exceptions or none | `T` |
| `void` return + checked exceptions | `Result[Unit, JvmException]` |

Unchecked exceptions (`RuntimeException` and `Error` subclasses) propagate
as unhandled bugs — the same as a contract violation — and are not wrapped.
The caller can convert them to `JvmException` via a future `Std.Jvm.catch`
intrinsic if needed (tracked under Q-J012).

`JvmException` is a single opaque wrapper over `java.lang.Exception`.
Callers that need to distinguish exception types call `typeName` and match
on the result string. A richer union-typed exception hierarchy is deferred
(Q-J010).

## 6. Naming convention

A Maven coordinate `groupId:artifactId` maps to a Lyric package path by:

1. **Group ID:** split on `.`, PascalCase each segment, concatenate.
   `com.fasterxml.jackson.core` → `ComFasterxmlJacksonCore`.
2. **Artifact ID:** split on `-`, `.`, and `_`, PascalCase each segment,
   concatenate.
   `jackson-databind` → `JacksonDatabind`; `scala_library` → `ScalaLibrary`.
3. **Lyric package path:** `{PascalGroup}.{PascalArtifact}`.

| Maven coordinate | Lyric package |
|---|---|
| `com.fasterxml.jackson.core:jackson-databind` | `ComFasterxmlJacksonCore.JacksonDatabind` |
| `org.postgresql:postgresql` | `OrgPostgresql.Postgresql` |
| `com.google.guava:guava` | `ComGoogleGuava.Guava` |
| `org.slf4j:slf4j-api` | `OrgSlf4j.Slf4jApi` |
| `io.netty:netty-all` | `IoNetty.NettyAll` |

Consumers import:
```
import ComFasterxmlJacksonCore.JacksonDatabind.{ObjectMapper, JsonNode}
```

Shim file path: `_extern/{PascalGroup}_{PascalArtifact}.l`
Skip log path: `_extern/{PascalGroup}_{PascalArtifact}.skip.md`

The full group ID is retained in the package name (not dropped) to prevent
collisions between packages from different organisations that share an
artifact ID. For example, `com.example:guava` and `com.google:guava` would
both reduce to `Guava` without the group, which is rejected.

## 7. Build pipeline integration

After `lyric restore`, the JVM emitter's module path includes:

1. The JVM stdlib JARs (`lyric.std.*.jar`).
2. The project's own `.jar`(s).
3. Every Maven JAR materialised in `target/restore/jars/`.

`lyric build` writes a `target/build/module-path.txt` listing all JARs in
order. The generated run-script wrapper invokes:

```sh
java --module-path "$(cat target/build/module-path.txt):target/build/<package>.jar" \
     --module lyric.<package>/<entry>
```

At compile time, `lyric-resolver.jar` provides the resolver with the
resolved JAR list. The JVM emitter loads each resolved JAR via
`ClassLoader` reflection to resolve `@externTarget` references, mirroring
the NuGet `Assembly.LoadFrom` path on the .NET side.

## 8. GraalVM native-image compatibility

`docs/18-jvm-emission.md` §22 establishes that Lyric-emitted code is
GraalVM native-image-compatible when targeting a native-image build. That
promise covers code Lyric *itself* emits. Maven JARs are out-of-scope:
many depend on reflection, dynamic class loading, or JNI that
`native-image` rejects or trims unsoundly.

The same enforcement model as .NET AOT (doc 21 §7) applies here:

- `lyric build` emits standard JVM bytecode.
- `native-image --module-path …` is run separately by the user.
  Trim warnings and native-image errors surface there, in standard
  GraalVM form.
- Lyric tooling does not maintain a "native-image-safe Maven allowlist."

Projects with `[maven]` entries forfeit the "all Lyric output is
native-image-compatible" guarantee unless each dep has been audited against
GraalVM's reachability-metadata repository. A future `lyric build
--native-image` flag will attempt to bundle reachability metadata from the
GraalVM Reachability Metadata Repository for known packages (Q-J009).

## 9. Security / supply-chain

Maven JARs execute arbitrary bytecode at runtime. Adding `[maven]` entries
inherits the Maven Central trust model.

Mitigations Lyric tooling adds on top:

- **Generated shim is a code-review artefact.** Reviewers see a diff of
  the public surface whenever a Maven dep is added or upgraded. Symbols
  that cross the package boundary are visible.
- **`@axiom("from Maven <groupId>:<artifactId> v<version>")`** appears
  verbatim in every contract resource. `lyric public-api-diff` lists axiom
  changes; a removed axiom is a SemVer-major event. Downstream consumers
  see exactly which Maven packages a published Lyric JAR trusts.
- **No transitive `@axiom` re-export.** A Lyric package consuming
  `ComGoogleGuava.Guava` does not transitively vouch for it; trust is
  local.
- **Checksum verification.** The bundled resolver verifies SHA-256 (with
  SHA-1 fallback for pre-2019 artifacts) against Maven Central's checksum
  service on every download. The local cache is write-once.
- **GPG signature verification** of downloaded JARs is out of scope for
  stage 1; noted under Q-J011.

## 10. Diagnostic codes

| Code | Meaning |
|---|---|
| `B0050` | Maven artifact failed to resolve (network error, not found, coordinate invalid, or checksum mismatch) |
| `B0051` | Maven artifact has no Java-21-compatible class files (TFM mismatch or too old) |
| `B0052` | Maven member skipped during shim generation (type-mapping failure) — informational, not an error |
| `B0053` | Auto-shim has been hand-edited and drifted from generated form; re-run `lyric restore` to regenerate |
| `B0054` | Maven coordinate specifies a SNAPSHOT version; SNAPSHOT dependencies are not supported |

## 11. Migration path

Existing JVM projects continue to work without changes. Adding a Maven
dependency is opt-in:

```toml
[maven]
"com.google.guava:guava" = "33.2.1-jre"
```

Then `lyric restore` downloads and caches the JAR and writes
`_extern/ComGoogleGuava_Guava.l`. After that, `import ComGoogleGuava.Guava.{ImmutableList}`
compiles. Version strings are passed through opaquely to the resolver —
Maven-style classifiers such as `-jre` and `-android` are not parsed by
Lyric and do not trigger `B0054`; only strings ending in `-SNAPSHOT` are
rejected.

Removing a dependency: drop the entry, run `lyric restore`, and delete (or
let the next restore prune) the auto-shim file.

## 12. Out of scope

- Direct reference to a JAR on disk. Always go through `[maven]` or the
  hand-written `extern package` path so the `@axiom` boundary is preserved.
- SNAPSHOT versions (`-SNAPSHOT` qualifier). The reproducibility contract
  (`target/restore/jars/` is deterministic given `lyric.toml`) requires
  immutable version strings.
- Custom or authentication-required Maven repositories. Stage 1 supports
  Maven Central only; custom feeds are a Phase 7 follow-up.
- Transitive auto-shims. Transitive JARs are restored to the classpath but
  do not receive `@axiom`-annotated shims unless the user declares them
  explicitly in `[maven]`.
- Gradle `build.gradle` / `build.gradle.kts` import. Only `lyric.toml`
  `[maven]` coordinates are supported.
- Kotlin-specific bytecode constructs (`suspend` functions, companion
  objects, `@JvmStatic` sugar). Skipped during shim generation with a
  `B0052` note.
- Source-level Maven packages (a Maven artifact whose contents are `.l`
  files). Lyric source distribution is via `lyric publish`, not Maven.

## 13. Open questions

### Q-J009: GraalVM reachability metadata auto-inclusion

`lyric build --native-image` should optionally pull reachability metadata
for known libraries from the GraalVM Reachability Metadata Repository and
bundle it alongside the native-image invocation. The mechanism (a
separately versioned metadata JAR per library) is well-defined; the work
is integrating it into the build driver.

**Recommended default:** defer to Phase 7. Document the manual step
(`-H:ConfigurationFileDirectories=…`) in `docs/22-distribution-and-tooling.md`.

### Q-J010: Richer exception union types

Wrapping all checked exceptions in a single `JvmException` loses
specificity. A richer design would auto-generate a union type per method
listing the declared exception classes. However, Java exception hierarchies
are deep and often contain dozens of subclasses; the union types would be
enormous and fragile to upstream changes.

**Recommended default:** keep the single `JvmException` wrapper. If a
specific library requires precise exception dispatch, the user can write a
thin hand-crafted `extern package` wrapper alongside the auto-shim.

### Q-J012: `Std.Jvm.catch` intrinsic for unchecked exceptions

Callers occasionally need to recover from unchecked `RuntimeException`
subclasses thrown by Java code (e.g. `NullPointerException` escaping a
poorly-written library). Today there is no Lyric-level way to intercept
unchecked exceptions without crashing the thread.

**Resolution:** `Std.Jvm.catch[T](action: func(): T): Result[T, JvmException]`
has been added to `stdlib/std/_kernel/jvm.l`, gated behind `@experimental`.
The declaration routes to `lyric.runtime.jvm.ExceptionHelper.catch` (a
static helper in the JVM stdlib kernel JAR that wraps a Callable). `Error`
subclasses are NOT caught (they propagate as unrecoverable JVM errors) per
the conservative bootstrap default. The JVM emitter call-site wrapper and
the `ExceptionHelper.catch` Java implementation are Phase 6 deliverables
(see Q-J013).

### Q-J013: JVM emitter call-site try-catch for checked-exception methods

When the JVM emitter compiles a call to an `@externTarget` function whose
declared Lyric return type is `Result[T, JvmException]` (i.e. a Java method
with checked exceptions in its `throws` clause), it must emit a try-catch
block rather than a plain `invokestatic` / `invokevirtual`:

1. Begin a protected region.
2. Emit the Java method call.
3. Box the return value into `Ok(result)`.
4. Catch `java.lang.Exception`; box the caught exception into `Err(exception)`.

This wrapping is NOT currently present in `compiler/lyric/jvm/lowering.l`.
The shim generator (`MavenShim.fs`) correctly declares the Lyric return type
as `Result[T, JvmException]` so the type checker accepts call sites correctly,
but the JVM emitter will produce incorrect bytecode (no try-catch) until this
is implemented.

`Std.Jvm.catch[T]` (Q-J012) similarly needs the JVM emitter to recognise the
`ExceptionHelper.catch` target and emit an `invokedynamic`/`invokestatic` +
exception-table entry rather than a direct call.

**Recommended default:** implement as part of the Phase 6 `@externTarget`
lowering pass in `compiler/lyric/jvm/`. Add an `LExternCall` instruction
variant (or annotate `LInvokestatic` / `LInvokevirtual` with a `checkedWrap`
flag) so `lowerFunc` emits the exception table entry automatically.

### Q-J011: GPG signature verification

Maven Central provides GPG signatures for most (but not all) packages.
Verifying them at restore time would strengthen the supply-chain story
but requires a GPG keyring and network access to the keyserver, and
currently about 15% of packages on Maven Central lack valid signatures.

**Recommended default:** skip for stage 1. Add `verify_signatures = true`
to `[maven.options]` as an opt-in in a follow-up, refusing packages
without valid GPG signatures when enabled.
