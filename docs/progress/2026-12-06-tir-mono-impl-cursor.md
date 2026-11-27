# TIR mono resumes each generic impl from its instance cursor (docs/70 phase 3c, D518)

## What shipped

- `Lyric.Tir.Mono` keeps a per-impl cursor into the instance list, so a generic impl is matched against each instance once instead of once per pass (D518).
- `tir_build_self_test.l`: tuple equality with a `Float` part (NaN rule) and a generic record leaf holding a tuple with an array (D515 review gaps).
