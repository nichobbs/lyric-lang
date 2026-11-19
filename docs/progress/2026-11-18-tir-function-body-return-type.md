# docs/70 phase 3a: a function body the checker left open takes the declared return type (D401)

`func empty[N: Nat](): Shape[N] = Shape.Empty` builds: the body's tail is settled at the declared return type, so the body is no longer counted (I0002).
