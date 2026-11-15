# D475 - The census judges a @test_module that imports compiler packages through `lyric test` (docs/70 §12.2, #8613)

**Status:** shipped.

## Context

The wide census builds each self-test with `lyric build --verify-ir`. A self-test that imports compiler packages (`Msil.*`, `Jvm.*`, `Lyric.*`) does not pass the ordinary check (T0020, T0010, T0014), because only `lyric test` links the compiler bundle as restored dependencies. 365 of 756 self-test builds were reported unchecked for that reason; `TIR_CENSUS_LINKED=1` existed but was off, and ran every unchecked program, including ones with no `lyric test` path.

## Decision

In the self-tests area, a build that prints no census line and whose source holds `@test_module` is run under `lyric test` (same census lines, the tests run too, about 25 s each) by default; `TIR_CENSUS_LINKED=0` turns that off. CI leaves the self-tests area out, so it is unaffected. A program with no `@test_module` (the numbered `msil_self_test_mNN.l` `func main` programs) has no path and stays listed as unchecked, with its exit code; the report counts entries correctly. `TIR_CENSUS_SELFTESTS="a.l b.l"` replaces the self-test list to check one change.

## Not covered

A full self-tests run takes hours; its numbers are posted on #8613 when measured.
