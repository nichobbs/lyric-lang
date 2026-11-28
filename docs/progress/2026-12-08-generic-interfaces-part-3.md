# Generic interfaces, part 3 (#7791)

Landed in part 3: native generic implementors for generic records (D864), the JVM narrowing of generic-interface call results so operators resolve (D866, #9459), native cross-package default methods (D869, #9451), an impl whose target is a union on dotnet and the JVM (D867) and on native for non-generic unions (D868), and by-value records used as interfaces lowering from TIR (D890, #9477). Remaining on native: an impl for a **generic** union (`impl[T] I for Wrap[T]`, N0105). Everything else of #7791 runs on dotnet, the JVM and native.
