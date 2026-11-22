# `Info(text = "t")` constructs the record when an enum case shares its name (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

A package declaring both `record Info` and `enum Level { case Info }`: the bare name resolved to the enum case, which takes no arguments, so the construction had no type (`erased_receiver_jvm_self_test.l`, #8633).

## Decision

`constructorSymbolOf` takes the package's own record (or opaque or protected type) of the name when the bare name resolves to an enum case or to nothing unique (`ownRecordNamed`).

## Results

`erased_receiver_jvm_self_test.l` 7 of 7 on the JVM.
