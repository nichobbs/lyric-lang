# D453 - A Nat widens to Long (docs/70 phase 3a, #8613)

**Status:** shipped; extends D319 (the typed IR).

## Context

`s.toLong()` on a `Nat`-backed range subtype or distinct type is typed by the checker at `Long` and records no callee. The builder unwraps the value to its underlying `Nat` and converts that to the call's type, but its numeric widening table (`Byte < Int < Long`, `Byte < UInt < ULong`, `Float < Double`) has no `Nat` entry, so the call was counted as "a conversion method whose result differs from the underlying type" (I0002).

## Decision

`widenKind` takes `Nat` to `Long`: a `Nat` is a non-negative `Long` (language reference 2.1), so the widening keeps every value and each backend already holds both in a 64-bit signed integer. The builder only converts between types the checker has already accepted, so this adds no program to the language.

## Results

`tir_build_self_test.l` builds `toLong` on a `Nat`-backed range subtype and distinct type with 0 I0002 and 0 I0003.
