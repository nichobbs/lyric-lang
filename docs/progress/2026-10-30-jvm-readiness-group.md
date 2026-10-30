# JVM readiness group: test-host UTF-8 console, auto-FFI supertype scoring, direct-signature test, docker and grpc JVM suites (#7686, #7446, #7194, #7511)

## #7686: test-host class sets up UTF-8 console streams

`Jvm.TestEngine.lowerTestModuleClass` now emits a `<clinit>` that runs the same
`System.setOut` / `System.setErr` UTF-8 rebinding as the synthesised `main`
wrapper (`Jvm.Codegen.emitConsoleUtf8Setup`, #7513). A JUnit or IDE harness
calls the `__lyric_test_<i>` methods directly and never runs `main`, so under a
C/POSIX locale its non-ASCII output would have turned into `?`.
`scripts/ci/test-host-locale-c-test.sh` builds the host class through
`self_test_b126.l`, loads it under `LC_ALL=C` and byte-compares a non-ASCII
line; it fails without the `<clinit>`. Wired into the JVM stdlib step of CI.

## #7446: JVM auto-FFI supertype scoring

`Jvm.AutoFfi.isAssignableRef` walked only the superclass chain and each class's
directly-declared interfaces, so an interface reached through a super-interface
(`List` to `Collection` to `Iterable`) scored as unverifiable (1) and lost to an
`Object` overload (3). It now searches the whole supertype graph, so a verified
supertype parameter scores 4 and wins, as the MSIL scorer's base-chain walk
does. Covered in `jvm_auto_ffi_bridge_self_test.l`.

Not done: trailing-default admission. Java has no default parameters; its
analogue is a varargs method (`ACC_VARARGS`), which also needs the call site to
pack the trailing arguments into an array. That is a code-generation change
across the static, instance and constructor call paths and is left open on the
issue.

## #7194: direct `collectFileSigsSeeded` path

`jvm_generic_call_result_cross_package_self_test.l` gained two cases that call
`collectFileCtors` and `collectFileSigsSeeded` on parsed packages and read the
registered signature's `recordRetClass`, so the unspecialised registration is
pinned without depending on `Lyric.Mono` leaving a call generic.

## #7511: JVM suites outside CI

`encoding_tests` and `xml_tests` already run on the JVM (batch script, #8441),
the stale `union_case_collision` header is already corrected, and the
generator-sdk suite is already in `jvm-ecosystem-suites.sh`. `lyric-docker` now
compiles on the JVM (the J008 is gone); its one Unix-socket fallback test is
gated to dotnet because the JVM has no Unix-domain-socket HTTP transport
(#2663). `lyric-docker` and `lyric-grpc` are added to the JVM ecosystem suites.
