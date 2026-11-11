# TIR builder: conversion methods on refined and distinct values, stubbable interface callees (D568, #8613)

Docs/70 phase 3a: `x.toInt()` on a range-subtype or distinct value builds as an unwrap, and a call of a
`@stubbable` interface's method resolves its callee. Census 1082 -> 1084 of 1165 bodies, I0003 0
(see D568). Phase 3a is not complete: I0002/I0003 do not stop the build yet.
