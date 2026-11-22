# `TimeSpan.new()` on a host value type is its zero value (docs/70 phase 3a, #8613)

**Status:** shipped; typed IR builder and verifier.

## Context

A host struct has an implicit parameterless constructor that no metadata lists, so `TimeSpan.new()` found no overload (`import_extern_self_test.l`).

## Decision

`new()` with no argument on a host type whose bases include `System.ValueType` and that declares no parameterless constructor is `XZeroValue` of the host type: its default value. `XZeroValue` is no longer only for arrays: the verifier also accepts a host (`TExtern`) type, and `tir_ir.l` says so.

## Results

`import_extern_self_test.l`: the `TimeSpan.new()` case builds.
