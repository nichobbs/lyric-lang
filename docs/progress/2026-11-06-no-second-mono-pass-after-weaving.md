# No second mono pass after weaving (docs/70 phase 3b S4, D393)

With every aspect woven before the check (D392), woven contracts are
specialised by the one ordinary mono run. `specialiseWovenContracts`,
`pipeWovenGenerics` and `pipeFinishWeave`'s `wovenGenerics` parameter are
deleted, and the M0009 diagnostic with them. docs/27 gains a note for template
authors: a value an aspect body names must be `pub`, and a name two imported
packages both declare must be qualified, because the spliced body is checked in
the consuming package (symptom: T0020 or T0123 "in code generated for this
declaration"). See D393.
