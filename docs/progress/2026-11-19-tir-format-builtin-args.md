# docs/70 phase 3a: `format1` to `format4` take arguments of any type (D407)

A call of `format1`-`format4` with a number or `Bool` argument builds as the built-in call, as `println`'s does, so the body is no longer counted (I0002). New shape `format_builtin_args`.
