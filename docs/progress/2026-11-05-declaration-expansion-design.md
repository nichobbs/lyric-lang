# Declaration expansion before body checking: design (docs/70 phase 3b, D370)

Design entry for phase 3b. Derives and the weaver move ahead of the checker
through one new step, `pipeExpandDeclarations`, at the head of `pipeCheckFront`,
so what they generate is checked like user code. Generated items are ordinary
AST items (the resolver collects them, `renumberNodeIds` numbers them after
them); until the checker's tables are keyed by `NodeId`, generated nodes take
unique spans from an allocator and a table maps each back to the declaration
that caused it, where diagnostics are reported. Four slices (derives, weaver
wrappers, templates and B'-mode, cleanup) each follow docs/70 section 12.2. No
behaviour change yet. See D370.
