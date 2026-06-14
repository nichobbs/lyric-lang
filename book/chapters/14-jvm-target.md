# Chapter 14: The JVM Target

Lyric defaults to .NET, but it also targets the JVM. `lyric build --target jvm` compiles your package to a standard `.jar` file. When fully shipped, that JAR will run on any Java 21-compatible runtime, publish to Maven Central, and be depended on by plain Java, Kotlin, or Scala projects without any adapter. Conversely, Lyric code running on the JVM will be able to depend on Maven packages through the `[maven]` table in `lyric.toml`.

The two targets share the same language, the same type system, the same contracts, and the same standard library surface. What differs is the output format and the platform-specific kernel that implements I/O and other runtime services. Switching targets is a compiler flag, not a code change — unless your code imports platform-specific `extern` packages.

::: note
**JVM status.** `lyric build --target jvm` is production-ready for the package shapes covered in this chapter. Maven dependency resolution (`[maven]` table in `lyric.toml`), `module-path.txt` generation, and async generators with `await` in their bodies are all fully implemented. Remaining gaps: GraalVM native-image integration and the `lyric run --target jvm` convenience wrapper (run via `java -jar` directly). These are noted inline where they arise.
:::

## §14.1 Building for the JVM

```sh
lyric build --target jvm <file.l>         # single file
lyric build --target jvm --manifest lyric.toml  # manifest-driven
```

The output is a plain `.jar` file. Lyric JARs are standard JARs — they have a `META-INF/MANIFEST.MF`, `.class` files, and can be placed on any Java classpath. The `MANIFEST.MF` carries Lyric-specific headers that the build driver uses to identify them:

```
Main-Class: lyric.account.Account$Funcs    (only on executable packages)
Lyric-Lang-Version: 0.1.0
Lyric-Package-Name: Account
Lyric-Package-SemVer: 1.2.0
Lyric-Manifest-SHA256: <hash>
```

The Lyric build driver looks for `Lyric-Lang-Version` when scanning JARs on the module path; no custom extension is needed (D060).

### §14.1.1 JPMS module identity

Every Lyric JAR is also a JPMS module (Java Platform Module System). The module name is `lyric.<package>` in lowercase, where the Lyric package name is lowercased dot-by-dot:

| Lyric package | JPMS module name        |
|---------------|-------------------------|
| `Account`     | `lyric.account`         |
| `Money.Cents` | `lyric.money.cents`     |
| `Std.Core`    | `lyric.std.core`        |

The `module-info.class` in the JAR lists every public Lyric type's namespace in `exports` directives, and every Lyric dependency as a `requires` directive. Internal types live in non-exported sub-namespaces and are unreachable across module boundaries.

### §14.1.2 Running a JVM build

For a package with `func main(): Unit`:

```sh
java --module-path "$(cat bin/module-path.txt):bin/account.jar" \
     --module lyric.account/lyric.account.Account$Funcs
```

`lyric build --target jvm` writes `bin/module-path.txt` alongside the output JAR when Maven dependencies were restored (i.e. `target/restore/jvm-classpath.txt` exists and contains at least one path). The file contains the colon-separated paths of all Maven JARs. `$(cat …)` expands the file inline because `--module-path` expects a colon-separated list, not a file reference. For packages with no `[maven]` entries, `module-path.txt` is not written and `--module-path` can be omitted or reference only the output JAR.

For a self-contained executable JAR with `Main-Class` set:

```sh
java -jar target/build/account.jar
```

## §14.2 What the output looks like from Java

Every `pub` type and `pub func` in a Lyric package is visible from Java. The naming follows a consistent pattern: the package's class namespace is `lyric.<package>.*` (lowercased), and the Lyric type name is preserved in UpperCamelCase.

### §14.2.1 Type mapping

| Lyric type   | Java type                  | Notes                                    |
|--------------|----------------------------|------------------------------------------|
| `Bool`       | `boolean` / `Boolean`      | boxed in generic position                |
| `Byte`       | JVM `int` in arithmetic    | unsigned 0–255; `byte` only at storage   |
| `Int`        | `int` / `Integer`          |                                          |
| `Long`       | `long` / `Long`            |                                          |
| `Float`      | `float` / `Float`          |                                          |
| `Double`     | `double` / `Double`        |                                          |
| `Char`       | `int` (Unicode code point) | not `char`; see §14.2.2                  |
| `String`     | `java.lang.String`         |                                          |
| `Unit`       | `void` / `java.lang.Void`  | `Void` in generic position               |
| `record T`   | Java record `T`            | `equals`, `hashCode`, `toString` auto-generated |
| `opaque T`   | final class `T` (no accessors) | construction guarded by module boundary |
| `union U`    | sealed interface `U`       | each `case C` is a record `implements U` |
| `List[T]`    | `java.util.List<T>`        | concrete type subject to finalisation    |

### §14.2.2 `Char` is a code point

Lyric `Char` is a Unicode scalar value (not a UTF-16 code unit). It maps to `int` on the JVM. There is no implicit conversion to Java `char`. Use `String.codePointAt` / `String.codePointCount` to go between Lyric `Char` values and Java `String`.

::: note
**Planned surface.** A conversion helper `Char.toUtf16Pair(c): (Char, Char?)` for code that genuinely needs surrogate pairs is planned for `lyric.std.text.unicode` but has not yet shipped.
:::

### §14.2.3 Records and opaque types

A Lyric `record Account { id: Long; balance: Long }` compiles to a Java record:

```java
public final record Account(long id, long balance) { … }
```

::: note
**Planned surface.** A `lyric.runtime.LyricRecord` marker interface and `@LyricOpaque` annotation for tooling (debugger, LSP) are planned but have not yet shipped. The class shapes above are correct; only the marker/annotation is deferred.
:::

An opaque type compiles to a final class with mangled private fields (names prefixed with `$`) and no public accessors. Construction is package-private; cross-module callers use the `pub` factory functions the Lyric source exposes.

### §14.2.4 Top-level functions

Top-level Lyric functions (not inside a record or interface) become `public static` methods on a generated class named `<package>$Funcs` (per `docs/18-jvm-emission.md` §11.1):

```lyric
// account.l
package Account

pub func deposit(acc: in Account, amount: in Long): Account { … }
```

```java
// Java caller
import lyric.account.Account;
import lyric.account.Account$Funcs;     // generated host class

Account updated = Account$Funcs.deposit(original, 100L);
```

## §14.3 Calling Lyric from Java

Adding a Lyric library to a Java project requires two things: the JAR on the module path, and a `requires` declaration in the Java module descriptor.

### §14.3.1 Maven / Gradle dependency

If the Lyric library is published to a Maven repository:

```xml
<!-- pom.xml -->
<dependency>
    <groupId>com.example</groupId>
    <artifactId>account</artifactId>
    <version>1.2.0</version>
</dependency>
```

```kotlin
// build.gradle.kts
dependencies {
    implementation("com.example:account:1.2.0")
}
```

For a locally built JAR, add it to the module path manually:

```sh
javac --module-path <lyric-runtime.jar>:<account.jar> …
```

### §14.3.2 JPMS module descriptor

For JPMS-modular Java projects, declare the dependency in `module-info.java`:

```java
module com.example.app {
    requires lyric.account;
    // Lyric.Std.Core is pulled in transitively via lyric.account's module-info
}
```

Non-modular projects (classpath-based) can use Lyric JARs as automatic modules without `module-info.java`.

### §14.3.3 Contracts at the boundary

Lyric contracts (`requires:` / `ensures:`) are enforced at runtime for `@runtime_checked` packages. A Java caller that violates a `requires:` clause will see a `lyric.runtime.ContractViolation` thrown (its exact JVM exception hierarchy is finalised in `docs/18-jvm-emission.md`). This is intentional: the contract is not just documentation, it is enforced.

For `@proof_required` packages, contracts are proved at Lyric compile time. Java callers bypass the proof but still see runtime checks in debug builds.

## §14.4 Testing on the JVM

`lyric test --jvm` compiles a `@test_module` file using the JVM backend and produces a JAR containing stub methods annotated with `@lyric.runtime.jvm.LyricTest`:

```sh
lyric test --jvm math_tests.l
```

Each `test "…" { … }` block becomes a `public static void __lyric_test_<i>()` method annotated with:

```java
@LyricTest(displayName = "addition works", sourceFile = "math_tests.l", sourceLine = 7)
```

The `@LyricTest` annotation carries `@Retention(RUNTIME)` and `@Target(METHOD)`, so it is visible to JVM tooling at runtime.

::: note
**Pending: full JUnit 5 engine.** `lyric test --jvm` compiles the test JAR and annotates test methods with `@LyricTest` but does not yet invoke JUnit 5's `ConsoleLauncher` or the `LyricTestEngine`. A TAP-shaped runner handles `.NET`-target tests; the full JVM `TestEngine` that discovers `@LyricTest` methods and reports to the JUnit Platform is in progress. See `docs/32-junit-runner-sketch.md`.
:::

### §14.4.1 JUnit 5 integration (in progress)

Once the full `LyricTestEngine` ships, `lyric test --jvm` will invoke the JUnit 5 `ConsoleLauncher` against the compiled test JAR:

```
Test run finished after 42 ms
[         3 tests found           ]
[         3 tests started         ]
[         3 tests successful      ]
[         0 tests failed          ]
```

You will also be able to run Lyric tests through any JUnit 5-compatible IDE or CI plugin (Maven Surefire, Gradle Test task, IntelliJ IDEA, Eclipse) by adding the Lyric test JAR to the test classpath. The `LyricTestEngine` registers itself via the `java.util.ServiceLoader` mechanism; no additional configuration is required.

### §14.4.2 What `@LyricTest` carries

| Annotation element | Type     | Content                              |
|--------------------|----------|--------------------------------------|
| `displayName`      | `String` | The test title from `test "…"`       |
| `sourceFile`       | `String` | Source file name, e.g. `math_tests.l`|
| `sourceLine`       | `int`    | Line number of the `test` declaration|

These are used by the `LyricTestEngine` for test display names and IDE navigation (jump-to-source), and are available to any custom JUnit 5 listener or reporter.

## §14.5 Maven dependencies in Lyric

Lyric JVM packages can depend on Maven Central libraries through the `[maven]` table in `lyric.toml`:

```toml
[maven]
"com.google.guava:guava" = "32.1.3-jre"
"org.apache.commons:commons-lang3" = "3.14.0"
```

Running `lyric restore` downloads the declared JARs to the local Maven cache (`~/.m2/repository/`) via `lyric-resolver.jar` and writes a classpath manifest at `target/restore/jvm-classpath.txt` (one JAR path per line). `lyric build --target jvm` reads that file and injects the JAR paths as `LYRIC_FFI_JARS` before invoking the self-hosted JVM emitter, so the auto-FFI resolver can find the Maven library's `.class` files and emit correct `invokevirtual`/`invokestatic` call sites. The build also copies `jvm-classpath.txt` to `bin/module-path.txt` so callers can pass it directly to `java --module-path`.

To call into a Maven library, declare an `extern type` binding in your Lyric source:

```lyric
import Std.Core

extern type ImmutableList = "com.google.common.collect.ImmutableList"

pub func example(): Unit {
  val xs = ImmutableList.of("a", "b", "c")
  Console.println(xs.toString())
}
```

The `lyric-resolver.jar` tool resolves coordinates, handles transitive dependencies, and stores downloaded JARs in the local Maven cache. It must be available beside the `lyric` binary, or pointed to via `LYRIC_MAVEN_RESOLVER`. If it is not found, `lyric restore` emits a note and succeeds (`.NET` builds are unaffected); a subsequent `lyric build --target jvm` will see no `LYRIC_FFI_JARS` and fail at type-resolution if Maven extern types are used.

For full details on the resolver protocol, version pinning, and the `[maven.options]` table, see `docs/31-maven-linking.md`.

## Exercises

1. **Hello from the JVM**

   Write a `func main(): Unit` that prints `"Hello from Lyric on the JVM!"`. Compile it with `lyric build --target jvm` and run it with `java -jar`. Confirm the output.

2. **Record round-trip**

   Define a `record Point { x: Int; y: Int }` and a `pub func` that returns one. Write a Java `main` method that imports the Lyric JAR, calls the function, and prints the point's `x` and `y` fields using the Java record accessor methods. Confirm that the Java record's `toString` produces a human-readable representation.

3. **JVM test run**

   Write a `@test_module` file with two `test` blocks: one that passes and one that deliberately fails with `assertTrue(false, "expected failure")`. Run `lyric test --jvm` and observe the output. Inspect the generated JAR with `jar -tf` to see the `@LyricTest`-annotated class.

4. **Type mapping exploration**

   Write a Lyric function that accepts `Int`, `Long`, `String`, and `Bool` parameters and returns a `record` containing all four. Compile to JVM and open the resulting class file with `javap -p -s` to see the exact Java descriptor the emitter chose for each parameter type. Compare the result to the type mapping table in §14.2.1.
