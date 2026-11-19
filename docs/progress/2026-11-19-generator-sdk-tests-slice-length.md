# lyric-generator-sdk: the tests size a slice with `.length`

Nine assertions in `lyric-generator-sdk/tests/generator_sdk_tests.l` read `.count` of a `slice[String]` (`ann.args.toArray().count == 0`), which is the checker error T0228 (only `List`, `Map` and `Set` have `.count`); `lyric test` reports a checker error as advisory, so the tests ran and passed with sixteen test bodies the typed-IR builder could not build (docs/70 phase 3a census, I0002). They read `.length` now: 58 of 58 pass and the bodies build.
