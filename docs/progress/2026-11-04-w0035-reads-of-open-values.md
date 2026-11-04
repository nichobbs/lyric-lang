# W0035 leaves a call fed by a read of an open-typed value alone (docs/70 phase 3a, D339)

Third round of the W0035 census. The CI logs of the second round showed seven
checker false positives in `lyric-ui` and `lyric-ws` (a loop variable of a
generic body, a member read, an index) and three true positives in
`core_tests.l`. A call with an argument that is a local, a member read or an
index whose type has a hole in it is now indeterminate and unreported;
constructions and calls are still judged. See D339.
