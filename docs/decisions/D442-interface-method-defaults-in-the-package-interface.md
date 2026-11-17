# D442 - An interface method's parameter defaults are written to the package interface (docs/70 phase 3a, #8613)

**Status:** shipped; extends D482 and D527.

## Context

D482 carries a function's and a body-carrying member's parameter defaults in the package interface, so a call from another package that leaves a defaulted argument out takes the declaring package's default. Interface methods are body-less (`IMSig`), so `memberSites`, the producer's source of member defaults, never saw them: a call through a restored interface (`Shape.area(scale = 2)`, `restored_default_args_self_test.l`) found no carried default and was counted as "a default argument declared in another package".

## Decision

The node mapper (`mapFileWith`, behind `renumberNodeIds` and every syntactic pass) skipped an interface method's parameters, so a default there kept `nodeId` 0 and the builder found no checker type for it. `IMSig` parameters are now mapped like a function's, so their defaults are numbered and visible to the passes that rewrite expressions.

`interfaceDefaultSites` makes a body-less member site of each non-generic interface method that declares a default, and `buildPackageDefaults` builds those next to the other members, keyed by the method's DefPath key and parameter name as for any member. A generic interface is left out (no carried form, as for a generic record). The consumer needs no change: it reads the key of the callee symbol, which for a call through an interface is the interface method's.

## Not covered

The JVM bridge checks a project's entry package before its siblings (D527); that ordering is a separate change.
