# resolver: pin the default-lifecycle Maven plugins so `resolver-build` does not depend on the runner's Maven

`resolver/pom.xml` pinned only the compiler, assembly and surefire plugins; the resources, jar, clean, install and deploy plugins took their versions from whichever Maven the runner image shipped. On 2026-11-19 the required `resolver-build` job started failing because the image's defaults moved to `maven-resources-plugin` 3.4.0, which did not resolve from Central on the runner ("Could not find artifact ... maven-resources-plugin:jar:3.4.0 in central").

The five lifecycle plugins are now pinned in `<pluginManagement>` at the versions Maven 3.9.11 uses (clean 3.2.0, resources 3.3.1, jar 3.4.1, install 3.1.2, deploy 3.1.2), all widely mirrored. `help:effective-pom` shows no other plugin on the `mvn package` path. This covers every CI and release job that runs `make maven-resolver` (the jobs that install Maven with apt as well as those on the runner's own Maven). The Maven binary itself is not pinned: the jobs obtain it three different ways, and with the plugins pinned its version no longer changes what the build resolves.

Verified: `make maven-resolver` from a clean `resolver/target` builds `lyric-resolver.jar`.
