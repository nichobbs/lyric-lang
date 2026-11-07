# D385 - The silent-TyError gate is the error I0001 (docs/70 5.3, 12.2, Q-TIR-001, #8613)

**Status:** shipped. Supersedes the opt-in form of D341: D341, D354, D355 and D357 describe the retired opt-in gate (W0036, `LYRIC_TYERR_GATE`); their text stays frozen.

## Context

D341 added the gate as the warning W0036, listed only with `LYRIC_TYERR_GATE=1`,
until no non-callee silent site remained. D354, D355, D357 and D359 closed the
census: the compiler, the standard library, the 81 library builds (CI job
`library-tyerr-census`) and the self-tests and examples that were checked report
none.

## Decision

`reportSilentTyErrors` adds the **error** I0001 ("internal: this X expression has
no type and no error was reported") for each non-callee silent site, always, with
no environment switch. A file that already has an error reports its own error and
not the cascades (unchanged). This is Q-TIR-001's answer, decided in D338: I0001
always stops the build; no profile or flag lowers it. The census scripts count
I0001 instead of W0036. A program that trips it is a checker bug, and the
failure names the construct and its position.
