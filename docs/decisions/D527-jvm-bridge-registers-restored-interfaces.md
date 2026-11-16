# D527 - The JVM bridge registers the interfaces of restored JARs (docs/70 phase 3a, #8613)

**Status:** shipped; extends D482 and D460.

## Context

A call that leaves out an argument another package declares takes the default that package's interface carries (D482). The MSIL project bridge reads each restored assembly's `Lyric.Interface.<Pkg>` resources into one `DepDefaults` store shared by every package of the build. The JVM bridge built each package's middle-end options with a fresh, empty store, so on `--target jvm` every such call was counted ("a default argument declared in another package"), although a JAR carries the same interface as `META-INF/lyric/<Pkg>.lyri` (`cli_interface.l` reads it for `lyric interface dump`).

## Decision

`Jvm.Bridge.registerRestoredInterfacesJvm` reads the `META-INF/lyric/*.lyri` entries of each restored JAR (`Std.Zip`, the limits `lyric interface dump` uses) into a store that `compileProjectToJarBundledWithRestored` and `checkProjectTypesJvm` create once per build and pass to every package's `MiddleEndOptions` (`runMiddleEnd` and `jvmMiddleEndOptions` take it as `depDefaults`). A JAR that cannot be read, or carries none, contributes nothing, and the call is counted as before.

## Results

`restored_default_args_self_test.l` (census): the `Rd.App` consumers built went from 9 to 11 of 20; the programs that leave a literal or `newList()` default out of a restored call now build on the JVM. The same interface also carries the defaults of the same-build packages, each registered as it is built (D482).

## Not covered

- On the JVM a project's entry package is checked before the packages it imports, so a same-build sibling's interface is not registered yet when its caller is checked; `tir-foreign-defaults-e2e.sh` over `--target jvm` still counts `g(7)`. The check order needs a first pass that registers each sibling's interface.
- Defaults declared on interface members and on restored `impl` members (`restored_default_args_self_test.l`: `Shape.area(scale = 2)`) are not carried by either target's interface; they are the remaining 6 sites of that program.
- The native bridge has no restored packages; its project builds have the same sibling-order question.
