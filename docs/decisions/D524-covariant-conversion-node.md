# D524 - Covariant conversion of a recursive union or a collection is a conversion node (docs/70 phase 3a, #8613)

**Status:** shipped; extends D487 and D488.

## Context

D487 and D488 rebuild a union value or a record at other type arguments (a `Result[English, String]` where a `Result[Greeter, String]` is wanted) as a `match` or a copy, with every payload converted. Two shapes cannot be written that way: a recursive union (`Tree[English]` as `Tree[Greeter]`) would need a `match` of unbounded depth, and a host collection (`List[Result[English, String]]` as `List[Result[Greeter, String]]`) is not a union at all. Both stayed counted (`covariant_conversion_self_test.l`: 36 of 38 bodies).

## Decision

`ConvKind` gains `CvCovariant`: a value used at the same generic type with other type arguments, each of which converts (equal, an interface upcast, a nullable of such, or itself covariant). `convertValue` takes it last, after the rebuilding rules, for a union, a record without `var` fields, or a `System.Collections.Generic.*` host collection. The verifier (`convert-type`) requires one head (the same declaration or host type) and one non-zero arity on both sides. How a backend represents the result, the same value or one rebuilt per argument, is its own choice, as for `CvUpcast`.

The package interface codec writes it as tag 12 and the dump prints `covariant`. A reader of the old form never sees the tag, and the format version stays 4.

## Not covered

A record with a `var` field has identity and stays counted. `slice[E]` as `slice[G]` and function types are not covariant here.
