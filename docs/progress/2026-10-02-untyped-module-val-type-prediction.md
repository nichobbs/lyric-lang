# Untyped module-level val: static field type prediction (AccessViolationException root cause)

An untyped module-level `val` initialised by a call or numeric conversion
(`val cap = 1800000.toLong()`, `val a = mk()`, `val n = s.length`) crashed the
process with an uncatchable `AccessViolationException` in
`CastHelpers.Unbox` as soon as it was copied into a local. This was the
root cause of the long-standing `streamSessionMessage` crash in cloud-agents
(`val runTimeoutMs = runWallClockCapMs`).

## Cause

`addPackageTokens` predicts each untyped module-level val's MSIL type
(`inferUntypedStaticValMsilType`) so that readers lowered before the
initializer can type their `ldsfld`. The predictor had no rule for calls or
conversions and answered `MObject`, while the field itself took the type the
initializer really lowers to (`int64`). The reader stored the raw `int64` into
an `object`-typed local with no `box`, and the next use did `unbox.any Int64`
on it. Reproduces in a 12-line program, independent of function size.

## Fix

- The predictor resolves calls to declared functions (via the same registry
  call lowering uses), `.toInt()/.toLong()/.toDouble()/...` conversions and
  `.length`/`.count`. Lambda bodies keep the conservative behaviour.
- `lowerMPackage` reports `F0047` when the real field type and the predicted
  type disagree across a CLR value type, so a remaining unpredicted shape is a
  build error instead of corrupt IL.
- Regression cases in `module_val_self_test.l` (including a reader declared
  before the val).
